-- | Routines for parsing and loading the log file.

module Resolver.Log(
                    LogFile(..),
                    ProcessingStep(..),
                    LinkChoice(..),
                    Successor(..),
                    Backpropagation(..),
                    ParentLink(..),
                    loadLogFile
                   )
    where

import Control.Exception
import Control.Monad.Reader
import Control.Monad.ST
import Data.Array
import Data.ByteString.Char8(ByteString)
import qualified Data.HashTable as HashTable
import Data.IORef
import Data.List(foldl')
import Data.Maybe(catMaybes, isJust, listToMaybe)
import Resolver.Parse
import Resolver.Types
import Resolver.Util(while)
import System.IO
import System.IO.Error
import Text.Parsec(runParser, getState, getPosition, setPosition, SourceName)
import Text.Parsec.ByteString()
import Text.Parsec.Pos(newPos)
import Text.Regex.Posix
import qualified Data.ByteString.Char8 as BS
import qualified Data.Map as Map
import qualified Data.Set as Set

type ProgressCallback = Integer -> Integer -> IO ()

data LogFile = LogFile { logFileH :: Handle,
                         -- ^ Get the file handle associated with this
                         -- log file.  Use this, for instance, to load
                         -- the text associated with a log entry.
                         logFilename :: String,
                         -- ^ Get the file name from which the log
                         -- file was loaded.
                         runs :: [[ProcessingStep]]
                         -- ^ Get the resolver runs contained in this
                         -- log, as sequences of processing steps, in
                         -- the order in which they were generated.
                       }

-- | Represents the choice associated with the link between two
-- processing steps, which might be unknown if not enough information
-- is available in the log file. (isomorphic to Maybe right now)
data LinkChoice = LinkChoice Choice
                | Unknown
                  deriving(Show, Ord, Eq)

-- | Represents the link from a parent solution to a child solution.
data ParentLink = ParentLink { parentLinkAction :: LinkChoice,
                               parentLinkForced :: Bool,
                               parentLinkParent :: ProcessingStep }

-- | A successor link either goes to a processing step, or it says
-- that a solution was generated as a successor but never processed.
data Successor = Successor { successorStep   :: ProcessingStep,
                             successorChoice :: LinkChoice,
                             successorForced :: Bool }
               | Unprocessed { successorSolution :: Solution,
                               successorChoice   :: LinkChoice,
                               successorForced   :: Bool }

-- | Represents backpropagating promotions up the search tree.
--
-- The step; the promotion is the new
-- promotion that was generated by this propagation.
data Backpropagation = Backpropagation { backpropagationStep :: ProcessingStep,
                                         backpropagationPromotion :: Promotion }

data ProcessingStep = ProcessingStep { -- | How we got here; Nothing
                                       -- if this is the root node or
                                       -- if we didn't see an
                                       -- indication of how this was
                                       -- generated.
                                       stepPredecessor :: Maybe ParentLink,
                                       -- | The search node generated by this step.
                                       stepSol :: Solution,
                                       -- | The order in which this
                                       -- step was performed.
                                       stepOrder :: Integer,
                                       -- | The successors of this
                                       -- step.
                                       stepSuccessors :: [Successor],
                                       -- | Promotions generated at
                                       -- this step.  Includes
                                       -- promotions propagated
                                       -- backwards from successor
                                       -- steps.
                                       stepPromotions :: Set.Set Promotion,
                                       -- | Backpropagations performed
                                       -- | at this step.
                                       stepBackpropagations :: [Backpropagation],
                                       -- | The first position in the
                                       -- log file of the log text for
                                       -- this step.
                                       stepTextStart :: Integer,
                                       -- | The length in the log file
                                       -- of the log text for this
                                       -- step.
                                       stepTextLength :: Integer,
                                       -- | The tree depth of this
                                       -- step (the longest chain to a
                                       -- leaf).
                                       stepDepth :: Integer,
                                       -- | The total size of the
                                       -- branch represented by this
                                       -- step.
                                       --
                                       -- Equal to the sum of the
                                       -- sizes of its children, plus
                                       -- one.
                                       stepBranchSize :: Integer
    }

-- | The type of step emitted when reading the input file, to avoid
-- having to "tie the knot" until the whole file has been scanned.
--
-- The differences relative to the full step structure are:
--
--  1. The parent step link is not stored.
--  2. Instead of storing successors, we store the solutions
--     attached to the successors, and the choice that generated
--     each solution.
--
-- A few values are also stored in odd ways (e.g., in reverse order)
-- so that this can be used as a "scratchpad" as the file is being
-- read.
data PartialStep = PartialStep { -- | The search node generated by this step.
                                 pstepSol :: !Solution,
                                 -- | The successors of this
                                 -- step, in reverse order.
                                 pstepReverseSuccessors :: ![(Solution, LinkChoice, Bool)],
                                 -- | Backpropagations at this step, in reverse order.
                                 pstepReverseBackpropagations :: ![(Solution, Promotion)],
                                 -- | Promotions generated at
                                 -- this step.
                                 pstepPromotions :: ![Promotion],
                                 -- | The first position in the
                                 -- log file of the log text for
                                 -- this step.
                                 pstepTextStart :: !Integer,
                                 -- | The length in the log file of
                                 -- the log text for this step, if
                                 -- known (if this is Nothing, we're
                                 -- still building the step).
                                 pstepTextLength :: !(Maybe Integer) }
                   deriving(Show, Ord, Eq)


-- | Make a new partial step storing the initial state of a step.
newPartialStep :: Solution -> Integer -> PartialStep
newPartialStep sol startPos =
    PartialStep {
  pstepSol = sol,
  pstepReverseSuccessors = [],
  pstepReverseBackpropagations = [],
  pstepPromotions = [],
  pstepTextStart = startPos,
  pstepTextLength = Nothing
}

-- | A synonym for makeRegex, specialized to the types we care about.
--
-- See lineParsers below for a list of which function processes each
-- line.
compile :: String -> Regex
compile = makeRegex

processingStepStart = compile "Processing (step [0-9]*: )?(.*)$"
newPromotion        = compile "Inserting new promotion: (.*)$"
-- Note: if we see a "forced" dependency and no "generated" line, we
-- magically know that the next "Processing" line will be for its
-- successor (and we use that to ensure that they get linked up).
successorsStart     = compile "(Generating successors for( step [0-9]* and dep)?|(Forced resolution )(\\(step [0-9]*\\) )?of) (.*)$"
madeSuccessor       = compile "Generated successor( \\(step [0-9]*\\))?: (.*)$"
tryingResolution    = compile "Trying to resolve (.*) by installing (.*)(from the dependency source)?$"
tryingUnresolved    = compile "Trying to leave (.*) unresolved$"
enqueuing           = compile "Enqueuing (.*)$"
successorsEnd       = compile "Done generating successors\\."
-- Start generating backpropagations.
backpropagationsBegin = compile "Backpropagating promotions to step ([0-9]*): (.*)$"
backpropagationAdd  = compile "Created backpropagated promotion at step ([0-9]*): (.*)$"

-- | The log lines we know how to parse: the first regex that matches
-- causes the corresponding function to be invoked on the match
-- results.  (matchOnce is used) The ByteString is the line that's
-- being matched.
lineParsers :: [(Regex, ByteString -> MatchArray -> LogParse ())]
lineParsers = [
 (processingStepStart, processStepStartLine),
 (newPromotion, processNewPromotionLine),
 (successorsStart, processSuccessorsStartLine),
 (tryingResolution, processTryingResolutionLine),
 (tryingUnresolved, processTryingUnresolvedLine),
 (madeSuccessor, processGeneratedLine),
 (successorsEnd, processSuccessorsEndLine),
 (backpropagationsBegin, processBackpropagationsBegin),
 (backpropagationAdd, processBackpropagationAdd) ]

data GeneratingSuccessorsInfo =
    GeneratingSuccessorsInfo { generatingForced :: !Bool,
                               generatingDep    :: !Dep }
    deriving(Show)

-- | The state used while loading the log file.
data LogParseState = LogParseState {
      -- | The state of the parser; we magically know that this
      -- contains intern sets that should be shared over all parse
      -- steps.
      logParseParseState :: !ParseState,
      -- | All the steps in the current run, in reverse order.  The
      -- first element in this list is the step currently being parsed
      -- (if any).
      logParseAllStepsReversed :: ![PartialStep],
      -- | All the runs in the file, in reverse order (but the runs
      -- are individually in order).
      logParseAllRunsReversed :: ![[PartialStep]],
      -- | The name of the file being parsed.  Read-only.
      logParseSourceName :: !String,
      -- | The current line.
      logParseCurrentLine :: !Int,
      -- | The file offset of the beginning of the current line.
      logParseCurrentLineStart :: !Integer,
      -- | Set to (Just dep) if we're between the beginning and end of
      -- generating successors for the dependency dep; otherwise
      -- Nothing.
      logParseGeneratingSuccessorsInfo :: !(Maybe GeneratingSuccessorsInfo),
      -- | All the promotions that have been seen so far.
      --
      -- Used to ensure that only new promotions are included in the
      -- promotions of a particular step.
      logParseSeenPromotions :: Maybe (HashTable.HashTable FastPromotion ()),
      -- | The last seen line indicating the resolver is examining a
      -- choice.
      --
      -- Could be "trying to resolve (dep) by installing (ver)", or
      -- "trying to leave (dep) unresolved".
      logParseLastSeenTryChoice :: !LinkChoice,
      -- | The solution, if any, that we are currently backpropagating
      -- promotions to.
      logParsePromotionBackpropagationState :: !(Maybe Solution)
    }

initialState sourceName =
    LogParseState { logParseParseState = initialParseState,
                    logParseAllStepsReversed = [],
                    logParseAllRunsReversed = [],
                    logParseSourceName = sourceName,
                    logParseCurrentLine = 0,
                    logParseCurrentLineStart = 0,
                    logParseGeneratingSuccessorsInfo = Nothing,
                    logParseSeenPromotions = Nothing,
                    logParseLastSeenTryChoice = Unknown,
                    logParsePromotionBackpropagationState = Nothing }

-- | The log parsing state monad.
type LogParse = ReaderT (IORef LogParseState) IO

get :: LogParse LogParseState
get = do ref <- ask
         lift $ readIORef ref

put :: LogParseState -> LogParse ()
put st = st `seq` do ref <- ask
                     liftIO $ writeIORef ref st

-- | Reset the parts of the state dealing with the current run and
-- insert the run into the list.
--
-- The argument is the file location that will be the "end" of the
-- run.
startNewRun :: Integer -> LogParse ()
startNewRun loc =
    do modifyLastStep (\lastStep -> lastStep { pstepTextLength = Just (loc - pstepTextStart lastStep) })
       st <- get
       let stepsRev = logParseAllStepsReversed st
           steps    = reverse stepsRev
           runsRev  = logParseAllRunsReversed st
           runsRev' = if null stepsRev then runsRev
                      else steps `seq` steps:runsRev
           st'      = runsRev' `seq`
                      st { logParseAllStepsReversed         = [],
                           logParseAllRunsReversed          = runsRev',
                           logParseGeneratingSuccessorsInfo = Nothing,
                           logParseSeenPromotions           = Nothing,
                           logParseLastSeenTryChoice        = Unknown }
       put st'

-- | Run a parser using the embedded state.
parse p sourceName source =
    do st <- get
       case runParser (do rval <- p
                          st'  <- getState
                          return (st', rval))
                      (logParseParseState st)
                      sourceName
                      source of
         Left err ->
             fail $ show err
         Right (parseState', rval) ->
             do put st { logParseParseState = parseState' }
                return rval

runLogParse :: String -> LogParse a -> IO a
runLogParse sourceName parser =
    do ref <- newIORef $ initialState sourceName
       runReaderT parser ref

-- Accessors.  We make the state strict in everything it contains.
getAllStepsReversed :: LogParse [PartialStep]
getAllStepsReversed = do st <- get
                         return $ logParseAllStepsReversed st

-- Backend; don't call (would mess up the strictness).
setAllStepsReversed :: [PartialStep] -> LogParse ()
setAllStepsReversed steps =
    steps `seq` do st <- get
                   put $ st { logParseAllStepsReversed = steps }

getAllRunsReversed :: LogParse [[PartialStep]]
getAllRunsReversed = do st <- get
                        return $ logParseAllRunsReversed st

getSourceName :: LogParse String
getSourceName = get >>= return . logParseSourceName

getCurrentLine :: LogParse Int
getCurrentLine = get >>= return . logParseCurrentLine

setCurrentLine :: Int -> LogParse ()
setCurrentLine n = n `seq` do st <- get
                              put $ st { logParseCurrentLine = n }

getCurrentLineStart :: LogParse Integer
getCurrentLineStart = get >>= return . logParseCurrentLineStart

setCurrentLineStart :: Integer -> LogParse ()
setCurrentLineStart n = n `seq` do st <- get
                                   put $ st { logParseCurrentLineStart = n }

getGeneratingSuccessorsInfo :: LogParse (Maybe GeneratingSuccessorsInfo)
getGeneratingSuccessorsInfo = get >>= return . logParseGeneratingSuccessorsInfo

promotionIsSeen :: Promotion -> LogParse Bool
promotionIsSeen p = do st <- get
                       (case logParseSeenPromotions st of
                          Nothing   -> return False
                          Just (ht) -> do found <- liftIO $ HashTable.lookup ht (makeFastPromotion p)
                                          return $ isJust found)

getOrMakeSeenPromotionsTable :: LogParse (HashTable.HashTable FastPromotion ())
getOrMakeSeenPromotionsTable =
    do st <- get
       case logParseSeenPromotions st of
         Just ht -> return ht
         Nothing -> do rval <- liftIO $ HashTable.new (==) fastPromotionHash
                       put st { logParseSeenPromotions = Just rval }
                       return rval

addSeenPromotion :: Promotion -> LogParse ()
addSeenPromotion p = do hashTable <- getOrMakeSeenPromotionsTable
                        liftIO $ HashTable.insert hashTable (makeFastPromotion p) ()

-- | Not strict in the contents of the Maybe.
setGeneratingSuccessorsInfo :: Maybe GeneratingSuccessorsInfo -> LogParse ()
setGeneratingSuccessorsInfo inf =
    inf `seq` do st <- get
                 put $ st { logParseGeneratingSuccessorsInfo = inf }

getLastSeenTryChoice :: LogParse LinkChoice
getLastSeenTryChoice = get >>= return . logParseLastSeenTryChoice

setLastSeenTryChoice :: LinkChoice -> LogParse ()
setLastSeenTryChoice c = c `seq` do st <- get
                                    put $ st { logParseLastSeenTryChoice = c }



incCurrentLine :: LogParse ()
incCurrentLine = do st <- get
                    put $ st { logParseCurrentLine = logParseCurrentLine st + 1 }

getLastStep :: LogParse (Maybe PartialStep)
getLastStep = do steps <- getAllStepsReversed
                 return $ listToMaybe steps

setLastStep :: PartialStep -> LogParse ()
setLastStep step' =
    do allSteps <- getAllStepsReversed
       case allSteps of
         [] -> error "No last step to modify."
         (step:steps) -> setAllStepsReversed (step':steps)

modifyLastStep :: (PartialStep -> PartialStep) -> LogParse ()
modifyLastStep f =
    do steps <- getAllStepsReversed
       unless (null steps)
              (let newFirstStep = f $ head steps in
               newFirstStep `seq`
               setAllStepsReversed $ (f $ head steps):(tail steps))

getPromotionBackpropagationState :: LogParse (Maybe Solution)
getPromotionBackpropagationState = get >>= return . logParsePromotionBackpropagationState

setPromotionBackpropagationState :: Maybe Solution -> LogParse ()
setPromotionBackpropagationState sol =
    do st <- get
       put $ st { logParsePromotionBackpropagationState = sol }

addBackpropagatedPromotionToCurrentStep :: Solution -> Promotion -> LogParse ()
addBackpropagatedPromotionToCurrentStep p sol =
    p `seq` sol `seq`
    modifyLastStep (\lastStep -> lastStep {
                                   pstepReverseBackpropagations =
                                       (p, sol):(pstepReverseBackpropagations lastStep)
                                 })


-- | Add a step at the end of the list of steps.
--
-- Strict in the new step.
addNewStep :: PartialStep -> LogParse ()
addNewStep step =
    step `seq`
         do allSteps <- getAllStepsReversed
            setAllStepsReversed (step:allSteps)

-- | Parses the given text from a regex match within a byte-string.
parseMatch :: Parser a
           -> ByteString
           -> (MatchOffset, MatchLength)
           -> LogParse a
parseMatch subParser source (start, length) =
    do when (start == (-1) || length == (-1))
            (fail "No match to parse.")
       sourceName <- getSourceName
       currentLine <- getCurrentLine
       let currentColumn = start
           pos = newPos sourceName currentLine currentColumn
           text = extract (start, length) source
       parse (setPosition pos >> subParser) sourceName text

-- | Close off the current step and start a new one, given the new
-- step's solution.
startNewStep :: Solution -> LogParse ()
startNewStep sol =
    do -- Close off the existing step.  The only thing
       -- that needs to be updated is its length.
      lineStart <- getCurrentLineStart
      modifyLastStep (\lastStep ->
                          let start = (pstepTextStart lastStep)
                              len   = lineStart - start in
                          len `seq` lastStep { pstepTextLength = Just len })
      -- Add the new step.
      sol `seq` addNewStep (newPartialStep sol lineStart)
      -- Reset state variables.
      setGeneratingSuccessorsInfo Nothing
      setLastSeenTryChoice Unknown
      setPromotionBackpropagationState Nothing

-- | Add a successor to a partial step.
--
-- The file-name and line number are taken as arguments in order to
-- produce a reasonable error if sanity-checking fails.
addSuccessor :: (Solution, LinkChoice, Bool) -> FilePath -> Int -> PartialStep -> PartialStep
addSuccessor succInf@(s, _, _) filename lineNum lastStep =
    -- Sanity-check to avoid circular deps:
    if pstepSol lastStep == s
    then if Set.null $ solBrokenDeps s
         -- If there are no broken dependencies, the runtime spits out
         -- a dummy "enqueuing" message for the full solution; we
         -- suppress this link to avoid cycles in the successor tree.
         then lastStep
         else error (filename ++ ":" ++ show lineNum ++ ": The solution " ++ show s ++ " is its own successor.")
    else
        let oldSuccessors = pstepReverseSuccessors lastStep
            newSuccessors = succInf:oldSuccessors in
        lastStep { pstepReverseSuccessors = newSuccessors }

-- | Process a line of the log file from a match array produced by
-- processingStepStart.
processStepStartLine :: ByteString -> MatchArray -> LogParse ()
processStepStartLine source matches =
    do sol <- parseMatch solution source (matches!2)
       loc <- getCurrentLineStart
       -- If the solution is empty, assume we're starting a new run.
       when (Map.null $ solChoices sol) (startNewRun loc)
       startNewStep sol

-- | Process a line of the log file if it looks like it produced a new
-- promotion.
processNewPromotionLine :: ByteString -> MatchArray -> LogParse ()
processNewPromotionLine source matches =
    do p <- parseMatch promotion source (matches!1)
       seen <- promotionIsSeen p
       unless seen $ do
         addSeenPromotion p
         -- Add the promotion to the current step.
         p `seq` modifyLastStep (\lastStep ->
                                     let oldPromotions = pstepPromotions lastStep
                                         newPromotions = (p:oldPromotions) in
                                     lastStep { pstepPromotions = newPromotions })

-- | Process a line of the log file that starts successor generation.
processSuccessorsStartLine :: ByteString -> MatchArray -> LogParse ()
processSuccessorsStartLine source matches =
    do d <- parseMatch dep source (matches!4)
       let forced = extract (matches!1) source == BS.pack "Forced resolution of"
       d `seq` forced `seq` setGeneratingSuccessorsInfo $
         Just (GeneratingSuccessorsInfo { generatingForced = forced,
                                          generatingDep    = d })

-- | Process a line of the log file that ends successor generation.
processSuccessorsEndLine :: ByteString -> MatchArray -> LogParse ()
processSuccessorsEndLine source matches =
    do setGeneratingSuccessorsInfo Nothing
       setLastSeenTryChoice Unknown

-- | Process a line of the log file that starts backpropagations for
-- the current step.
--
-- This currently just assumes that backpropagations happen only once
-- per step.
processBackpropagationsBegin :: ByteString -> MatchArray -> LogParse ()
processBackpropagationsBegin source matches =
    do sol <- parseMatch solution source (matches!2)
       sol `seq` setPromotionBackpropagationState (Just sol)

-- | Process a line of the log file that indicates that a new
-- backpropagation was emitted.
processBackpropagationAdd :: ByteString -> MatchArray -> LogParse ()
processBackpropagationAdd source matches =
    do maybeSol <- getPromotionBackpropagationState
       (case maybeSol of
          Nothing  -> return ()
          Just sol ->
              do p <- parseMatch promotion source (matches!2)
                 seen <- promotionIsSeen p
                 unless seen $ do
                   addSeenPromotion p
                   p `seq` sol `seq` addBackpropagatedPromotionToCurrentStep sol p)

-- | Process a line of the log file that indicates that a particular
-- resolution was attempted.
--
-- This might not be a "real" resolution, but we remember it anyway
-- for future use. (I'd like to attach this information to *all* the
-- promotions that we generate, for instance)
processTryingResolutionLine :: ByteString -> MatchArray -> LogParse ()
processTryingResolutionLine source matches =
    do d <- parseMatch dep source (matches!1)
       v <- parseMatch version source (matches!2)
       let fromDep = (fst (matches!3) /= (-1))
           c = InstallVersion {
                 choiceVer = v,
                 choiceVerReason = (Just d),
                 choiceFromDepSource = (Just fromDep)
               }
           lc = LinkChoice c
       d `seq` v `seq` c `seq` lc `seq`
         setLastSeenTryChoice lc

processTryingUnresolvedLine :: ByteString -> MatchArray -> LogParse ()
processTryingUnresolvedLine source matches =
    do d <- parseMatch dep source (matches!1)
       let c = BreakSoftDep d
       let lc = LinkChoice c
       c `seq` lc `seq` d `seq` setLastSeenTryChoice lc

-- | Process a line of the log file that indicates that a new solution
-- is being inserted into the queue.
processGeneratedLine :: ByteString -> MatchArray -> LogParse ()
processGeneratedLine source matches =
    do s <- parseMatch solution source (matches!2)
       lastSeenChoice <- getLastSeenTryChoice
       fn <- getSourceName
       lineNum <- getCurrentLine
       succInf <- getGeneratingSuccessorsInfo
       forced <- (case succInf of
                    Just GeneratingSuccessorsInfo { generatingForced = forced' }
                        -> return forced'
                    Nothing
                        -> return False)

       -- If we see a "generated successor" line when the last
       -- successor was forced, then we forced two dependencies at
       -- once, and we should insert a new step for the previous one
       -- (otherwise it would look like both were children of the same
       -- parent, and one of them was never visited).  "generated
       -- successor" lines will insert into the successors list, so
       -- look there.
       maybeLastStep <- getLastStep
       (case maybeLastStep of
          (Just (PartialStep { pstepReverseSuccessors = (lastSol, _, True):_ })) ->
              startNewStep lastSol
          _ -> return ())

       -- NB: I assume here that the last-seen choice object was made
       -- strict when it was entered into the parse state.
       s `seq`
         modifyLastStep $ addSuccessor (s, lastSeenChoice, forced) fn lineNum


-- | Process a single line of the log file.
processLogLine :: ByteString -> LogParse ()
processLogLine line =
    -- Lazily test whether each regex matches this line, and apply the
    -- given function if it does.
    --
    -- I could say
    --
    --     fmap (const f) $ matchOnce regex line
    --
    -- but that has the downside that it's too clever by half.
    let matches = [case matchOnce regex line of
                     Just arr -> Just (f line arr)
                     Nothing  -> Nothing
                   | (regex, f) <- lineParsers] in
    -- Evaluate the first match, if there is one; otherwise do
    -- nothing.
    head (catMaybes matches ++ [return ()])

forEachLine :: Handle -> (ByteString -> LogParse ()) -> ProgressCallback -> LogParse ()
forEachLine h f progress = do total <- liftIO $ hFileSize h
                              while (liftIO (hIsEOF h) >>= return . not) (doLine total) ()
    where doLine :: Integer -> LogParse ()
          doLine total =
              do loc <- liftIO $ hTell h
                 liftIO $ progress loc total
                 setCurrentLineStart loc
                 nextLine <- liftIO $ BS.hGetLine h >>= return
                 f nextLine
                 incCurrentLine

-- Extract predecessor links in terms of solutions, in an arbitrary
-- order.
extractPredecessorLinks :: [PartialStep] -> [(Solution, (Solution, LinkChoice, Bool))]
extractPredecessorLinks [] = []
extractPredecessorLinks (step:steps) =
    [(childSolution, (pstepSol step, childChoice, forced))
     | (childSolution, childChoice, forced) <- pstepReverseSuccessors step]
    ++ extractPredecessorLinks steps

-- | Map a list of partial processing steps (in order) to a collection
-- of processing steps.
extractProcessingSteps :: [PartialStep] -> [ProcessingStep]
extractProcessingSteps partialSteps =
    -- Tricky: we need to "tie the knot".  We build a bunch of
    -- recursive auxiliary lookup tables in the "where" (lazily), and
    -- use "convert" (also in the "where") to build the output list
    -- using those.
    let rval = [convert step | step <- partialSteps] in
    rval `seqList` rval
    where
      convert :: PartialStep -> ProcessingStep
      convert pstep = stepMap Map.! (pstepSol pstep)
      -- A lazily generated map that gives the step object for each
      -- solution.
      stepMap :: Map.Map Solution ProcessingStep
      stepMap = Map.fromList [((pstepSol pstep), makeStep n pstep)
                              | (n, pstep) <- (zip [0..] partialSteps)]
      -- Another lazily generated map that gives the parent link (if
      -- any) of each solution.
      parentMap :: Map.Map Solution ParentLink
      parentMap = Map.fromList [(child, ParentLink { parentLinkAction = c,
                                                     parentLinkForced = forced,
                                                     parentLinkParent = (stepMap Map.! parent) })
                                | (child, (parent, c, forced)) <- extractPredecessorLinks partialSteps]
      -- Builds a successor link for the given solution.
      findSuccessor :: Solution -> Solution -> LinkChoice -> Bool -> Successor
      findSuccessor oldSol sol c forced =
          if oldSol == sol
          then error $ "How can " ++ (show sol) ++ " be its own successor?"
          else case Map.lookup sol stepMap of
                 Just step -> Successor step c forced
                 Nothing   -> Unprocessed sol c forced

      findBackpropagation :: (Solution, Promotion) -> Backpropagation
      findBackpropagation (sol, p) =
          case Map.lookup sol stepMap of
            Just step -> step `seq` p `seq` Backpropagation { backpropagationStep = step,
                                                              backpropagationPromotion = p }
            Nothing -> error $ "No match for the solution " ++ show sol ++ " when adding the backpropagated promotion " ++ show p

      -- How to build an output step from an input step.  This is
      -- where the knot gets tied, using stepMap.  It works because
      -- the key values in the map can be computed without having to
      -- resolve any recursive references (so the map structure is
      -- well-defined).
      makeStep :: Integer -> PartialStep -> ProcessingStep
      makeStep n pstep =
          let sol            = pstepSol pstep
              psuccessors    = reverse $ pstepReverseSuccessors pstep
              successors     = [findSuccessor sol sol' c forced
                                    | (sol', c, forced) <- psuccessors]
              pbackprops     = reverse $ pstepReverseBackpropagations pstep
              backprops      = map findBackpropagation pbackprops
              promotions     = Set.fromList $ pstepPromotions pstep
              succDepth succ = case succ of
                                 Successor { successorStep = step } -> stepDepth step
                                 Unprocessed {} -> 0
              depth          = maximum (0:(map succDepth successors)) + 1
              succSize succ  = case succ of
                                 Successor { successorStep = step } -> stepBranchSize step
                                 Unprocessed {} -> 1
              branchSize     = sum (map succSize successors) + 1
              start          = pstepTextStart pstep
              len            = case pstepTextLength pstep of
                                 Just len -> len
                                 Nothing -> error $ "Internal error: missing text length in step " ++ (show n) ++ "."
          in
          sol `seq` n `seq` depth `seq` branchSize `seq` promotions `seq` start `seq` len `seq` ProcessingStep {
        stepPredecessor = Map.lookup sol parentMap,
        stepSol = sol,
        stepOrder = n,
        stepSuccessors = successors,
        stepPromotions = promotions,
        stepBackpropagations = backprops,
        stepTextStart  = start,
        stepTextLength = len,
        stepDepth      = depth,
        stepBranchSize = branchSize
      }

-- Debugging stuff: a manual deepSeq-type of function that can be used
-- to selectively de-lazy the state (hence providing a way to track
-- down which state component is accumulating thunks and killing us).
forceMaybe :: (a -> b) -> Maybe a -> ()
forceMaybe f (Just v) = f v `seq` ()
forceMaybe f Nothing = ()

forceMap :: (a -> b) -> [a] -> ()
forceMap f xs = foldl' (flip seq) () (map f xs)

forceEverything :: LogParse a -> LogParse a
forceEverything a =
    do st <- get
       let forceSteps = () --forceMap forceStep $ logParseAllStepsReversed st
           forceSourceName = () -- forceMap id $ logParseSourceName st
           forceSuccessors = () -- forceMaybe forceDep $ logParseGeneratingSuccessorsInfo st
           forceTryChoice = () -- logParseLastSeenTryChoice st `seq` () -- forceMaybe forceChoice $ logParseLastSeenTryChoice st
       forceSteps `seq` forceSourceName `seq` forceSuccessors `seq` forceTryChoice `seq` a
    where
      forceStep pstep =
          --forceSol (pstepSol pstep) `seq`
          --forceMap (\(s, c) -> forceSol s `seq` forceChoice c `seq` ()) (pstepReverseSuccessors pstep) `seq`
          forceMap forcePromotion (pstepPromotions pstep) `seq`
          pstepTextStart pstep `seq`
          forceMaybe id (pstepTextLength pstep) `seq`
          ()
      forceSol sol = ()
      forcePromotion p = ()
      forceDep (Dep source solvers isSoft) = forceMap forceVersion solvers `seq` forceVersion source `seq` isSoft `seq` ()
      forceChoice (InstallVersion ver dep fromDepSource) =
          forceVersion ver `seq` forceMaybe forceDep dep `seq` forceMaybe id fromDepSource `seq` ()
      forceChoice (BreakSoftDep dep) =
          forceDep dep `seq` ()
      forceVersion (Version p name) =
          forcePkg p `seq` BS.length name `seq` ()
      forcePkg (Package name) =
          BS.length name `seq` ()


seqList :: [a] -> b -> b
seqList lst x = foldr seq x lst

processFile :: Handle -> ProgressCallback -> LogParse LogFile
processFile h progress =
    do sourceName <- getSourceName
       forEachLine h processLogLine progress
       --forEachLine h $ (\s -> forceEverything $ processLogLine s)
       -- The last step won't have a length because we update it when
       -- we add a new step; fix that.
       loc <- liftIO $ hTell h
       startNewRun loc -- Force the current run onto the runs list.
       runsReversed <- getAllRunsReversed
       let runs     = reverse runsReversed
           outRuns  = map extractProcessingSteps runs
       (map seqList outRuns) `seqList` return $ LogFile h sourceName outRuns

-- | Load a log file from a handle.
--
-- The callback is invoked with the current file position and the file
-- size, in that order.
loadLogFile :: Handle -> String -> ProgressCallback -> IO LogFile
loadLogFile h sourceName progress =
    do runLogParse sourceName (processFile h progress)
