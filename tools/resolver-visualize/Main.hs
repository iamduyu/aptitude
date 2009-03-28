#!/usr/bin/env runhaskell

module Main where

import Control.Monad.Reader
import qualified Control.Monad.State as State
import Control.Monad.Trans(liftIO)
import Data.ByteString.Char8 as ByteString(ByteString, empty, hGet, pack, unpack)
import Data.List(intersperse)
import Graphics.UI.Gtk
import Graphics.UI.Gtk.Glade
import Graphics.UI.Gtk.SourceView
import Numeric
import System.Environment(getArgs)
import System.Glib.MainLoop
import System.Glib.Types
import Data.IORef
import Data.Maybe
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Tree
import Resolver.Log
import Resolver.Types
import Resolver.Util
import System.IO
import System.Time

xmlFilename = "resolver-visualize.glade"

data MainLoopContext = MainLoopContext { mainLoop :: MainLoop,
                                         numMainWindows :: IORef Integer }

type MainM = ReaderT MainLoopContext IO

runMain :: (MainM a) -> MainLoopContext -> IO a
runMain = runReaderT

mainWindowClosed :: MainM ()
mainWindowClosed = do ctx <- ask
                      liftIO $ do modifyIORef (numMainWindows ctx) (+(-1))
                                  num <- readIORef (numMainWindows ctx)
                                  when (num == 0) (mainLoopQuit (mainLoop ctx))

mainWindowOpened :: MainM ()
mainWindowOpened = do ctx <- ask
                      liftIO $ modifyIORef (numMainWindows ctx) (+1)

-- | Information about a loaded log file.
data LoadedLogFile =
    LoadedLogFile { logFile :: LogFile }

data TextColumnInfo = TextColumnInfo { textColumn   :: TreeViewColumn,
                                       textRenderer :: CellRendererText }

textColumnNew :: String -> IO TextColumnInfo
textColumnNew name = do col      <- treeViewColumnNew
                        treeViewColumnSetTitle col name
                        renderer <- cellRendererTextNew
                        cellLayoutPackEnd col renderer True
                        return TextColumnInfo { textColumn   = col,
                                                textRenderer = renderer }

-- | Information about the columns and renderers of the tree display.
data TreeViewColumnInfo =
    TreeViewColumnInfo { treeViewText        :: TextColumnInfo,
                         treeViewNumChoices  :: TextColumnInfo,
                         treeViewBrokenDeps  :: TextColumnInfo,
                         treeViewStepNum     :: TextColumnInfo,
                         treeViewChildren    :: TextColumnInfo,
                         treeViewHeight      :: TextColumnInfo,
                         treeViewSubtreeSize :: TextColumnInfo,
                         treeViewTier        :: TextColumnInfo,
                         treeViewScore       :: TextColumnInfo }

treeViewColumnInfoRenderers :: TreeViewColumnInfo -> [CellRenderer]
treeViewColumnInfoRenderers inf =
    [ toCellRenderer $ textRenderer $ treeViewText inf,
      toCellRenderer $ textRenderer $ treeViewNumChoices inf,
      toCellRenderer $ textRenderer $ treeViewBrokenDeps inf,
      toCellRenderer $ textRenderer $ treeViewStepNum inf,
      toCellRenderer $ textRenderer $ treeViewChildren inf,
      toCellRenderer $ textRenderer $ treeViewHeight inf,
      toCellRenderer $ textRenderer $ treeViewSubtreeSize inf,
      toCellRenderer $ textRenderer $ treeViewTier inf,
      toCellRenderer $ textRenderer $ treeViewScore inf ]

treeViewColumnInfoColumns :: TreeViewColumnInfo -> [TreeViewColumn]
treeViewColumnInfoColumns inf =
    [ textColumn $ treeViewText inf,
      textColumn $ treeViewNumChoices inf,
      textColumn $ treeViewBrokenDeps inf,
      textColumn $ treeViewStepNum inf,
      textColumn $ treeViewChildren inf,
      textColumn $ treeViewHeight inf,
      textColumn $ treeViewSubtreeSize inf,
      textColumn $ treeViewTier inf,
      textColumn $ treeViewScore inf ]

-- | Discard attribute bindings for the tree view.
treeViewColumnInfoClear :: TreeViewColumnInfo -> IO ()
treeViewColumnInfoClear inf = let cols = treeViewColumnInfoColumns inf in
                              mapM_ cellLayoutClear cols

newTreeViewColumns :: IO TreeViewColumnInfo
newTreeViewColumns =
    do text              <- textColumnNew "Description"
       numChoices        <- textColumnNew "Choices"
       brokenDeps        <- textColumnNew "Broken Deps"
       stepNum           <- textColumnNew "Order"
       children          <- textColumnNew "Children"
       height            <- textColumnNew "Height"
       subtreeSize       <- textColumnNew "Size"
       tier              <- textColumnNew "Tier"
       score             <- textColumnNew "Score"
       return TreeViewColumnInfo { treeViewText          = text,
                                   treeViewNumChoices    = numChoices,
                                   treeViewBrokenDeps    = brokenDeps,
                                   treeViewStepNum       = stepNum,
                                   treeViewChildren      = children,
                                   treeViewHeight        = height,
                                   treeViewSubtreeSize   = subtreeSize,
                                   treeViewTier          = tier,
                                   treeViewScore         = score }

-- | Information about the columns and renderers of the chronological
-- display.
data ChronologicalViewColumnInfo =
    ChronologicalViewColumnInfo { chronViewNumChoices  :: TextColumnInfo,
                                  chronViewBrokenDeps  :: TextColumnInfo,
                                  chronViewStepNum     :: TextColumnInfo,
                                  chronViewChildren    :: TextColumnInfo,
                                  chronViewHeight      :: TextColumnInfo,
                                  chronViewSubtreeSize :: TextColumnInfo,
                                  chronViewTier        :: TextColumnInfo,
                                  chronViewScore       :: TextColumnInfo }

chronViewColumnInfoRenderers :: ChronologicalViewColumnInfo -> [CellRenderer]
chronViewColumnInfoRenderers inf =
    [ toCellRenderer $ textRenderer $ chronViewNumChoices inf,
      toCellRenderer $ textRenderer $ chronViewBrokenDeps inf,
      toCellRenderer $ textRenderer $ chronViewStepNum inf,
      toCellRenderer $ textRenderer $ chronViewChildren inf,
      toCellRenderer $ textRenderer $ chronViewHeight inf,
      toCellRenderer $ textRenderer $ chronViewSubtreeSize inf,
      toCellRenderer $ textRenderer $ chronViewTier inf,
      toCellRenderer $ textRenderer $ chronViewScore inf ]

chronViewColumnInfoColumns :: ChronologicalViewColumnInfo -> [TreeViewColumn]
chronViewColumnInfoColumns inf =
    [ textColumn $ chronViewNumChoices inf,
      textColumn $ chronViewBrokenDeps inf,
      textColumn $ chronViewStepNum inf,
      textColumn $ chronViewChildren inf,
      textColumn $ chronViewHeight inf,
      textColumn $ chronViewSubtreeSize inf,
      textColumn $ chronViewTier inf,
      textColumn $ chronViewScore inf ]

-- | Discard attribute bindings for the chronological view.
chronViewColumnInfoClear :: ChronologicalViewColumnInfo -> IO ()
chronViewColumnInfoClear inf = let cols = chronViewColumnInfoColumns inf in
                               mapM_ cellLayoutClear cols

newChronViewColumns :: IO ChronologicalViewColumnInfo
newChronViewColumns =
    do numChoices        <- textColumnNew "Choices"
       brokenDeps        <- textColumnNew "Broken Deps"
       stepNum           <- textColumnNew "Order"
       children          <- textColumnNew "Children"
       height            <- textColumnNew "Height"
       subtreeSize       <- textColumnNew "Size"
       tier              <- textColumnNew "Tier"
       score             <- textColumnNew "Score"
       return ChronologicalViewColumnInfo {
                    chronViewNumChoices   = numChoices,
                    chronViewBrokenDeps   = brokenDeps,
                    chronViewStepNum      = stepNum,
                    chronViewChildren     = children,
                    chronViewHeight       = height,
                    chronViewSubtreeSize  = subtreeSize,
                    chronViewTier         = tier,
                    chronViewScore        = score
                  }

-- | Information about the columns and renderers of the run list.
data RunListColumnInfo =
    RunListColumnInfo { runListNumber :: TextColumnInfo,
                        runListLength :: TextColumnInfo }

runListInfoRenderers :: RunListColumnInfo -> [CellRenderer]
runListInfoRenderers inf =
    [ toCellRenderer $ textRenderer $ runListNumber inf,
      toCellRenderer $ textRenderer $ runListLength inf ]

runListInfoColumns :: RunListColumnInfo -> [TreeViewColumn]
runListInfoColumns inf =
    [ textColumn $ runListNumber inf,
      textColumn $ runListLength inf ]

-- | Discard attribute bindings for the run list.
runListColumnInfoClear :: RunListColumnInfo -> IO ()
runListColumnInfoClear inf = let cols = runListInfoColumns inf in
                             mapM_ cellLayoutClear cols

newRunListColumns :: IO RunListColumnInfo
newRunListColumns =
    do number     <- textColumnNew "Run Number"
       len        <- textColumnNew "Run Length"
       return RunListColumnInfo {
                    runListNumber = number,
                    runListLength = len
                  }

type TreeViewStore  = TreeStore TreeViewEntry
type ChronViewStore = ListStore ChronViewEntry
type RunListStore   = ListStore (Integer, [ProcessingStep])
-- | Shared context for the visualizer.
data VisualizeContext =
    VisualizeContext { treeView :: TreeView,
                       treeViewColumnInfo :: TreeViewColumnInfo,
                       treeViewStore :: TreeViewStore,
                       chronologicalView :: TreeView,
                       chronologicalViewColumnInfo :: ChronologicalViewColumnInfo,
                       chronologicalViewStore :: ChronViewStore,
                       runList :: TreeView,
                       runListColumnInfo :: RunListColumnInfo,
                       runListStore :: RunListStore,
                       logView :: SourceView,
                       mainContext :: MainLoopContext,
                       loadedFile :: IORef (Maybe LoadedLogFile),
                       activeRun  :: IORef (Maybe (Integer, [ProcessingStep])) }

-- | State monad for the visualizer.
type VisM = ReaderT VisualizeContext IO

-- Accessors for state.
runVis :: (VisM a) -> VisualizeContext -> IO a
runVis = runReaderT

getTreeView :: VisM TreeView
getTreeView = do ctx <- ask; return $ treeView ctx

getTreeViewStore :: VisM TreeViewStore
getTreeViewStore = do ctx <- ask; return $ treeViewStore ctx

getTreeViewColumnInfo :: VisM TreeViewColumnInfo
getTreeViewColumnInfo = do ctx <- ask; return $ treeViewColumnInfo ctx

getChronologicalView :: VisM TreeView
getChronologicalView = do ctx <- ask; return $ chronologicalView ctx

getChronologicalViewColumnInfo :: VisM ChronologicalViewColumnInfo
getChronologicalViewColumnInfo = do ctx <- ask; return $ chronologicalViewColumnInfo ctx

getChronologicalViewStore :: VisM ChronViewStore
getChronologicalViewStore = do ctx <- ask; return $ chronologicalViewStore ctx

getRunList :: VisM TreeView
getRunList = do ctx <- ask; return $ runList ctx

getRunListColumnInfo :: VisM RunListColumnInfo
getRunListColumnInfo = do ctx <- ask; return $ runListColumnInfo ctx

getRunListStore :: VisM RunListStore
getRunListStore = do ctx <- ask; return $ runListStore ctx

getLogView :: VisM SourceView
getLogView = do ctx <- ask; return $ logView ctx

getMainCtx :: VisM MainLoopContext
getMainCtx = do ctx <- ask; return $ mainContext ctx


getLog :: VisM (Maybe LogFile)
getLog = do ctx <- ask
            maybeInf <- liftIO $ readIORef $ loadedFile ctx
            return $ fmap logFile maybeInf

getRunNumber :: VisM (Maybe Integer)
getRunNumber = do ctx <- ask
                  runInf <- liftIO $ readIORef $ activeRun ctx
                  return $ fmap fst runInf

isActiveRun :: Integer -> VisM Bool
isActiveRun n = do current <- getRunNumber
                   case current of
                     Nothing   -> return False
                     (Just n') -> return (n == n')

--getTreeViewStore :: VisM (Maybe (TreeStore TreeViewEntry))
--getTreeViewStore = do ctx <- ask
--                      maybeInf <- liftIO $ readIORef $ loadedFile ctx
--                      return $ fmap treeViewStore maybeInf

-- | Stores tree-structure information about an entry.
data EntryTreeInfo = EntryTreeInfo {
      treeInfoChildren    :: Integer,
      treeInfoHeight      :: Integer,
      treeInfoSubtreeSize :: Integer
    } deriving(Ord, Eq, Show)

getTreeInfo :: ProcessingStep -> EntryTreeInfo
getTreeInfo (ProcessingStep { stepSuccessors = steps,
                              stepDepth      = height,
                              stepBranchSize = branchSize }) = EntryTreeInfo { treeInfoChildren    = toInteger $ length steps,
                                                                               treeInfoHeight      = height,
                                                                               treeInfoSubtreeSize = branchSize }

-- Each row in the tree display is either the root of the search, a
-- processing step (possibly with no parent!), a solution that was
-- enqueued but never visited, or a note about a problem rendering the
-- tree.
data TreeViewEntry =
    Root {
      entryStep         :: ProcessingStep,
      entryNumChoices   :: Integer,
      entryBrokenDeps   :: Integer,
      entryStepNum      :: Integer,
      entryTreeInfo     :: EntryTreeInfo
    }
  | Step {
      entryStep         :: ProcessingStep,
      entryChoice       :: LinkChoice,
      entryNumChoices   :: Integer,
      entryBrokenDeps   :: Integer,
      entryStepNum      :: Integer,
      entryTreeInfo     :: EntryTreeInfo
    }
  -- | A Step node would have been produced, but the
  -- same solution was already generated as a Step
  -- node.  The attached Solution node could be used
  -- to, e.g., look up the tree node associated with
  -- the link.
  | AlreadyGeneratedStep {
      entrySol          :: Solution,
      entryChoice       :: LinkChoice,
      entryNumChoices   :: Integer,
      entryStepNum      :: Integer,
      entryBrokenDeps   :: Integer,
      entryTextStart    :: Integer,
      entryTextLength   :: Integer
    }
  | NoStep {
      entrySol          :: Solution,
      entryChoice       :: LinkChoice,
      entryBrokenDeps   :: Integer,
      entryNumChoices   :: Integer
    }
  | Error {
      entryErrorText    :: String,
      entryStepNum      :: Integer
    }

forceList :: [a] -> [a]
forceList = foldr (\a b -> a `seq` (a:b)) []

-- | The tree-view building monad contains local state remembering
-- which nodes have already been incorporated into the tree, so we
-- don't display them more than once.
type BuildTreeView = State.State (Set.Set Solution)
unfoldSuccessor :: Successor -> BuildTreeView (TreeViewEntry, [Successor])
unfoldSuccessor (Successor step choice forced) =
    do seen <- State.get
       let sol        = stepSol step
           stepNum    = stepOrder step
       (if sol `Set.member` seen
        then let numChoices = toInteger $ Map.size $ solChoices sol
                 brokenDeps = toInteger $ Set.size $ solBrokenDeps sol
                 textStart  = stepTextStart step
                 textLength = stepTextLength step in
             return $ sol `seq` choice `seq` stepNum `seq` textStart `seq`
                    textLength `seq` numChoices `seq` brokenDeps `seq`
                                   (AlreadyGeneratedStep { entrySol        = sol,
                                                           entryChoice     = choice,
                                                           entryStepNum    = stepNum,
                                                           entryNumChoices = numChoices,
                                                           entryBrokenDeps = brokenDeps,
                                                           entryTextStart  = textStart,
                                                           entryTextLength = textLength },
                                    [])
        else let newState       = Set.insert sol seen
                 numChoices     = toInteger $ Map.size $ solChoices $ stepSol step
                 brokenDeps     = toInteger $ Set.size $ solBrokenDeps $ stepSol step
                 treeInfo       = getTreeInfo step in
             step `seq` choice `seq` stepNum `seq` newState `seq`
             numChoices `seq` brokenDeps `seq` treeInfo `seq`
             do State.put $ Set.insert sol seen
                return (Step { entryStep       = step,
                               entryChoice     = choice,
                               entryStepNum    = stepNum,
                               entryNumChoices = numChoices,
                               entryBrokenDeps = brokenDeps,
                               entryTreeInfo   = treeInfo },
                        forceList $ stepSuccessors step))
unfoldSuccessor (Unprocessed sol choice forced) =
    let brokenDeps = toInteger $ Set.size $ solBrokenDeps sol
        numChoices = toInteger $ Map.size $ solChoices sol in
    sol `seq` choice `seq` brokenDeps `seq` numChoices `seq`
    return (NoStep { entrySol = sol,
                     entryChoice = choice,
                     entryBrokenDeps = brokenDeps,
                     entryNumChoices = numChoices },
            [])

runToForest :: [ProcessingStep] -> Forest TreeViewEntry
runToForest steps = case steps of
                      [] -> [Node (Error { entryErrorText = "No steps in this run.",
                                           entryStepNum = 0 }) []]
                      (root:rest) -> State.evalState (makeWholeTree root rest) Set.empty
    where makeTree :: (ProcessingStep -> TreeViewEntry) -> ProcessingStep -> BuildTreeView (Maybe (Tree TreeViewEntry))
          makeTree f root =
              do seen <- State.get
                 let rootSol = stepSol root
                 (if rootSol `Set.member` seen
                  then return $ Nothing
                  else do State.put $ Set.insert rootSol seen
                          let rootSucc = stepSuccessors root
                          succ <- unfoldForestM unfoldSuccessor rootSucc
                          return $ f `seq` root `seq` forceList succ `seq` Just $ Node (f root) succ)
          makeWholeTree :: ProcessingStep -> [ProcessingStep] -> BuildTreeView (Forest TreeViewEntry)
          makeWholeTree root rest =
              do first <- makeTree makeRootTree root
                 -- This is always the first node we
                 -- process, so it should never
                 -- appear in "seen".
                 when (not $ isJust first) (error "Internal error: how can the root be seen already?")
                 rest' <- sequence $ map (makeTree makeOrphanedTree) rest
                 return $ catMaybes (first:rest')
          makeRootTree     root = let numChoices = toInteger $ Map.size $ solChoices $ stepSol root
                                      brokenDeps = toInteger $ Set.size $ solBrokenDeps $ stepSol root
                                      stepNum = stepOrder root
                                      treeInfo = getTreeInfo root in
                                  root `seq` numChoices `seq` brokenDeps `seq` stepNum `seq` treeInfo `seq`
                                  Root { entryStep       = root,
                                         entryNumChoices = numChoices,
                                         entryBrokenDeps = brokenDeps,
                                         entryStepNum    = stepOrder root,
                                         entryTreeInfo   = getTreeInfo root }
          makeOrphanedTree root = let numChoices = toInteger $ Map.size $ solChoices $ stepSol root
                                      brokenDeps = toInteger $ Set.size $ solBrokenDeps $ stepSol root
                                      stepNum = stepOrder root
                                      treeInfo = getTreeInfo root in
                                  root `seq` numChoices `seq` brokenDeps `seq` stepNum `seq` treeInfo `seq`
                                  Step { entryStep       = root,
                                         entryChoice     = Unknown,
                                         entryNumChoices = numChoices,
                                         entryBrokenDeps = brokenDeps,
                                         entryStepNum    = stepNum,
                                         entryTreeInfo   = treeInfo }

class PP a where
    ppS :: a -> ShowS

instance PP Version where
    ppS (Version pkg verName) = ppS pkg . (' ':) . (unpack verName++)

instance PP Package where
    ppS (Package pkgName) = (unpack pkgName++)

instance PP Dep where
    ppS (Dep src solvers isSoft) = let arrow = if isSoft
                                               then " -S> {"
                                               else " -> {" in
                                   ppS src . (arrow++) . (\x -> foldr (++) x $ intersperse ", " $ map pp solvers) . ('}':)

pp x = ppS x ""

choiceText :: LinkChoice -> String
choiceText (LinkChoice (InstallVersion ver _ _)) = "Install " ++ pp ver
choiceText (LinkChoice (BreakSoftDep d)) = "Break " ++ pp d
choiceText Unknown = "(...)"

-- Column definitions for tree view entries.
entryColumnText :: TreeViewEntry -> String
entryColumnText (Root {}) = "Root"
entryColumnText (Step { entryChoice = choice}) = choiceText choice
entryColumnText (AlreadyGeneratedStep { entryChoice = choice }) = "Already seen: " ++ choiceText choice
entryColumnText (NoStep { entryChoice = choice }) = "Never visited: " ++ choiceText choice
entryColumnText (Error { entryErrorText = err }) = err

entryColumnNumChoices :: TreeViewEntry -> String
entryColumnNumChoices (Root { entryNumChoices = n })                    = show n
entryColumnNumChoices (Step { entryNumChoices = n })                    = show n
entryColumnNumChoices (AlreadyGeneratedStep { entryNumChoices = n })    = show n
entryColumnNumChoices (NoStep { entryNumChoices = n })                  = show n
entryColumnNumChoices (Error {})                                        = ""

entryColumnBrokenDeps :: TreeViewEntry -> String
entryColumnBrokenDeps (Root { entryBrokenDeps = n })                    = show n
entryColumnBrokenDeps (Step { entryBrokenDeps = n })                    = show n
entryColumnBrokenDeps (AlreadyGeneratedStep { entryBrokenDeps = n })    = show n
entryColumnBrokenDeps (NoStep { entryBrokenDeps = n })                  = show n
entryColumnBrokenDeps (Error {})                                        = ""

entryColumnStepNum :: TreeViewEntry -> String
entryColumnStepNum (Root { entryStepNum = n })                          = show n
entryColumnStepNum (Step { entryStepNum = n })                          = show n
entryColumnStepNum (AlreadyGeneratedStep { entryStepNum = n })          = show n
entryColumnStepNum (NoStep {})                                          = ""
entryColumnStepNum (Error {})                                           = ""

entryColumnChildren :: TreeViewEntry -> String
entryColumnChildren (Root { entryTreeInfo = inf })                      = show $ treeInfoChildren inf
entryColumnChildren (Step { entryTreeInfo = inf })                      = show $ treeInfoChildren inf
entryColumnChildren (AlreadyGeneratedStep {})                           = ""
entryColumnChildren (NoStep { })                                        = ""
entryColumnChildren (Error {})                                          = ""


entryColumnHeight :: TreeViewEntry -> String
entryColumnHeight (Root { entryTreeInfo = inf })                        = show $ treeInfoHeight inf
entryColumnHeight (Step { entryTreeInfo = inf })                        = show $ treeInfoHeight inf
entryColumnHeight (AlreadyGeneratedStep { })                            = ""
entryColumnHeight (NoStep { })                                          = ""
entryColumnHeight (Error {})                                            = ""

entryColumnSubtreeSize :: TreeViewEntry -> String
entryColumnSubtreeSize (Root { entryTreeInfo = inf })                   = show $ treeInfoSubtreeSize inf
entryColumnSubtreeSize (Step { entryTreeInfo = inf })                   = show $ treeInfoSubtreeSize inf
entryColumnSubtreeSize (AlreadyGeneratedStep { })                       = ""
entryColumnSubtreeSize (NoStep { })                                     = ""
entryColumnSubtreeSize (Error {})                                       = ""

entryColumnTier :: TreeViewEntry -> String
entryColumnTier (Root { entryStep = step })                             = show $ solTier $ stepSol step
entryColumnTier (Step { entryStep = step })                             = show $ solTier $ stepSol step
entryColumnTier (AlreadyGeneratedStep { entrySol = sol })               = show $ solTier sol
entryColumnTier (NoStep { entrySol = sol })                             = show $ solTier sol
entryColumnTier (Error {})                                              = ""

entryColumnScore :: TreeViewEntry -> String
entryColumnScore (Root { entryStep = step })                            = show $ solScore $ stepSol step
entryColumnScore (Step { entryStep = step })                            = show $ solScore $ stepSol step
entryColumnScore (AlreadyGeneratedStep { entrySol = sol })              = show $ solScore sol
entryColumnScore (NoStep { entrySol = sol })                            = show $ solScore sol
entryColumnScore (Error {})                                             = ""

renderTreeView :: [ProcessingStep] -> TreeViewStore -> IO ()
renderTreeView steps model = do let forest = runToForest steps
                                treeStoreClear model
                                mapM_ (\(n, tree) -> treeStoreInsertTree model [] n tree)
                                      (zip [0..] forest)

data ChronViewEntry =
    ChronStep { chronNumChoices   :: Integer,
                chronBrokenDeps   :: Integer,
                chronStepNum      :: Integer,
                chronChildren     :: Integer,
                chronHeight       :: Integer,
                chronSubtreeSize  :: Integer,
                chronTier         :: Tier,
                chronScore        :: Integer,
                chronStep         :: ProcessingStep }

makeChronStep :: ProcessingStep -> ChronViewEntry
makeChronStep step =
    let numChoices  = toInteger $ Map.size $ solChoices $ stepSol step
        brokenDeps  = toInteger $ Set.size $ solBrokenDeps $ stepSol step
        stepNum     = stepOrder step
        children    = toInteger $ length $ stepSuccessors step
        height      = stepDepth step
        subtreeSize = stepBranchSize step
        tier        = solTier $ stepSol step
        score       = solScore $ stepSol step in
    numChoices `seq` brokenDeps `seq` stepNum `seq` children `seq` height `seq` subtreeSize `seq` step `seq` tier `seq` score `seq`
    ChronStep { chronNumChoices  = numChoices,
                chronBrokenDeps  = brokenDeps,
                chronStepNum     = stepNum,
                chronChildren    = children,
                chronHeight      = height,
                chronSubtreeSize = subtreeSize,
                chronStep        = step,
                chronTier        = tier,
                chronScore       = score }

renderChronView :: [ProcessingStep] -> ChronViewStore -> IO ()
renderChronView steps model =
    do let list = [ makeChronStep step | step <- steps ]
       listStoreClear model
       mapM_ (listStoreAppend model) list

showText :: Integer -> Integer -> VisM ()
showText start len =
    do log      <- getLog
       logView  <- getLogView
       liftIO $ do
         logBuffer <- textViewGetBuffer logView
         (case log of
            Nothing -> textBufferSetText logBuffer ""
            Just f  -> do let h = logFileH f
                          hSeek h AbsoluteSeek start
                          s <- ByteString.hGet h (fromInteger len)
                          textBufferSetText logBuffer $ unpack s)

stepSelected :: Maybe ProcessingStep -> VisM ()
stepSelected Nothing = return () -- Clear the log view?
stepSelected (Just step) = showText (stepTextStart step) (stepTextLength step)

setupTextColumn inf model ops =
    cellLayoutSetAttributes (textColumn inf) (textRenderer inf) model ops

setRun :: Maybe (Integer, [ProcessingStep]) -> VisM ()
setRun Nothing =
    do treeView         <- getTreeView
       chronView        <- getChronologicalView

       treeStore        <- getTreeViewStore
       chronStore       <- getChronologicalViewStore

       treeViewColInfo  <- getTreeViewColumnInfo
       chronViewColInfo <- getChronologicalViewColumnInfo

       liftIO $ do treeStoreClear treeStore
                   listStoreClear chronStore

setRun (Just (n, steps)) =
    do isActive <- isActiveRun n
       unless isActive $
            do ctx <- ask
               treeView         <- getTreeView
               chronView        <- getChronologicalView

               treeStore        <- getTreeViewStore
               chronStore       <- getChronologicalViewStore

               treeViewColInfo  <- getTreeViewColumnInfo
               chronViewColInfo <- getChronologicalViewColumnInfo

               logView <- getLogView
               liftIO $ do -- Update the UI for the new log file.
                 rawLogViewBuffer <- textViewGetBuffer logView
                 textBufferSetText rawLogViewBuffer ""

                 renderTreeView  steps treeStore
                 renderChronView steps chronStore

setLog :: LogFile -> VisM ()
setLog lf =
    do runModel <- getRunListStore
       runView  <- getRunList
       ctx      <- ask
       liftIO $ do listStoreClear runModel
                   mapM_ (listStoreAppend runModel) $ (zip [1..] $ runs lf)
                   -- Make sure the first iterator is selected.
                   firstIter <- treeModelGetIterFirst runModel
                   selection <- treeViewGetSelection runView
                   (case firstIter of
                      Nothing -> return ()
                      Just i  -> treeSelectionSelectIter selection i)
                   writeIORef (loadedFile ctx) $ Just LoadedLogFile { logFile = lf }
       return ()

-- | Load a widget from the Glade file by name.
loadXmlWidget :: WidgetClass a => String -> (GObject -> a) -> IO (GladeXML, a)
loadXmlWidget widgetName cast =
    do x <- xmlNewWithRootAndDomain xmlFilename (Just widgetName) Nothing
       case x of
         Nothing -> error ("Can't load " ++ (show xmlFilename))
         Just xml -> do w <- xmlGetWidget xml cast widgetName
                        return (xml, w)

-- | Load the main window from the Glade file.
loadMainWindowXML :: IO (GladeXML, Window)
loadMainWindowXML = loadXmlWidget "main_window" castToWindow

-- | Load the About box from the Glade file.
loadAboutBoxXML :: IO (GladeXML, AboutDialog)
loadAboutBoxXML = loadXmlWidget "about_box" castToAboutDialog

-- | Load the loading progress window from the Glade file.
loadLoadingProgressXML :: IO (GladeXML, Window)
loadLoadingProgressXML = loadXmlWidget "window_load_progress" castToWindow

setupMainWindow :: GladeXML -> IO SourceView
setupMainWindow xml =
    do sourceViewHolder <- xmlGetWidget xml castToScrolledWindow "scrolledwindow_sourceview"
       sourceView <- sourceViewNew
       sourceViewSetShowLineNumbers sourceView True
       textViewSetEditable sourceView False
       containerAdd sourceViewHolder sourceView
       return sourceView

createMainWindowColumns :: GladeXML -> MainM (TreeViewColumnInfo, ChronologicalViewColumnInfo, RunListColumnInfo)
createMainWindowColumns xml =
    liftIO $ do treeViewCols  <- newTreeViewColumns
                chronViewCols <- newChronViewColumns
                runListCols   <- newRunListColumns
                return (treeViewCols, chronViewCols, runListCols)

createMainWindowStores :: TreeViewColumnInfo -> ChronologicalViewColumnInfo -> RunListColumnInfo -> IO (TreeViewStore, ChronViewStore, RunListStore)
createMainWindowStores treeViewInf chronViewInf runListInf = do
  treeModel    <- treeStoreNew []
  chronModel   <- listStoreNew []
  runModel     <- listStoreNew []
  -- Set up column bindings.
  let makeCol info model (getCol, getText) =
          setupTextColumn (getCol info) model
                          (\row -> [cellText := getText row])
      treeCols   = [(treeViewText,         entryColumnText),
                    (treeViewNumChoices,   entryColumnNumChoices),
                    (treeViewBrokenDeps,   entryColumnBrokenDeps),
                    (treeViewStepNum,      entryColumnStepNum),
                    (treeViewChildren,     entryColumnChildren),
                    (treeViewHeight,       entryColumnHeight),
                    (treeViewSubtreeSize,  entryColumnSubtreeSize),
                    (treeViewTier,         entryColumnTier),
                    (treeViewScore,        entryColumnScore)]
      chronCols  = [(chronViewNumChoices,  show . chronNumChoices),
                    (chronViewBrokenDeps,  show . chronBrokenDeps),
                    (chronViewStepNum,     show . chronStepNum),
                    (chronViewChildren,    show . chronChildren),
                    (chronViewHeight,      show . chronHeight),
                    (chronViewSubtreeSize, show . chronSubtreeSize),
                    (chronViewTier,        show . chronTier),
                    (chronViewScore,       show . chronScore)]
      runCols = [(runListNumber,     show . fst),
                 (runListLength,     show . length . snd)]
  mapM_ (makeCol treeViewInf treeModel) treeCols
  mapM_ (makeCol chronViewInf chronModel) chronCols
  mapM_ (makeCol runListInf runModel) runCols
  return (treeModel, chronModel, runModel)

treeSelectionChanged :: VisualizeContext -> TreeSelection -> TreeViewStore -> IO ()
treeSelectionChanged ctx selection model = do
  num <- treeSelectionCountSelectedRows selection
  (if num /= 1
   then runVis (stepSelected Nothing) ctx
   else do (Just selected) <- treeSelectionGetSelected selection
           path            <- treeModelGetPath model selected
           node            <- treeStoreLookup model path
           (case node of
              Nothing   -> runVis (stepSelected Nothing) ctx
              Just (Node {rootLabel = Root {entryStep = step}}) -> runVis (stepSelected (Just step)) ctx
              Just (Node {rootLabel = Step {entryStep = step}}) -> runVis (stepSelected (Just step)) ctx
              Just (Node {rootLabel = AlreadyGeneratedStep { entryTextStart  = start,
                                                             entryTextLength = len }})
                  -> runVis (showText start len) ctx
              _ -> runVis (stepSelected Nothing) ctx))

chronSelectionChanged :: VisualizeContext -> TreeSelection -> ChronViewStore -> IO ()
chronSelectionChanged ctx selection model = do
  num <- treeSelectionCountSelectedRows selection
  (if num /= 1
   then runVis (stepSelected Nothing) ctx
   else do (Just selected) <- treeSelectionGetSelected selection
           (i:_)           <- treeModelGetPath model selected
           entry           <- listStoreGetValue model i
           runVis (stepSelected $ Just $ chronStep entry) ctx)

runSelectionChanged :: VisualizeContext -> TreeSelection -> RunListStore -> IO ()
runSelectionChanged ctx selection model = do
  num <- treeSelectionCountSelectedRows selection
  (if num /= 1
   then runVis (setRun Nothing) ctx
   else do (Just selected) <- treeSelectionGetSelected selection
           (i:_) <- treeModelGetPath model selected
           run <- listStoreGetValue model  i
           runVis (setRun (Just run)) ctx)

newCtx :: GladeXML -> MainM VisualizeContext
newCtx xml =
    do mainCtx <- ask
       (treeViewColInf, chronViewColumnInf, runListColumnInf) <- createMainWindowColumns xml
       liftIO $ do sourceView <- setupMainWindow xml
                   treeView <- xmlGetWidget xml castToTreeView "tree_view_search_tree"
                   chronView <- xmlGetWidget xml castToTreeView "tree_view_search_history"
                   runView <- xmlGetWidget xml castToTreeView "tree_view_run_list"
                   mapM_ (treeViewAppendColumn treeView)      (treeViewColumnInfoColumns treeViewColInf)
                   mapM_ (treeViewAppendColumn chronView)     (chronViewColumnInfoColumns chronViewColumnInf)
                   mapM_ (treeViewAppendColumn runView)   (runListInfoColumns runListColumnInf)
                   (treeModel, chronModel, runModel) <-
                       createMainWindowStores treeViewColInf chronViewColumnInf runListColumnInf

                   lf <- newIORef Nothing
                   runRef <- newIORef Nothing

                   let ctx = VisualizeContext { treeView = treeView,
                                                treeViewColumnInfo = treeViewColInf,
                                                treeViewStore = treeModel,
                                                chronologicalView = chronView,
                                                chronologicalViewColumnInfo = chronViewColumnInf,
                                                chronologicalViewStore = chronModel,
                                                runList = runView,
                                                runListColumnInfo = runListColumnInf,
                                                runListStore = runModel,
                                                logView = sourceView,
                                                loadedFile = lf,
                                                activeRun = runRef,
                                                mainContext = mainCtx }

                   treeSelection <- treeViewGetSelection treeView
                   treeSelectionSetMode treeSelection SelectionSingle
                   afterSelectionChanged treeSelection (treeSelectionChanged ctx treeSelection treeModel)

                   chronSelection <- treeViewGetSelection chronView
                   treeSelectionSetMode chronSelection SelectionSingle
                   afterSelectionChanged chronSelection (chronSelectionChanged ctx chronSelection chronModel)

                   runSelection <- treeViewGetSelection runView
                   treeSelectionSetMode runSelection SelectionSingle
                   afterSelectionChanged runSelection (runSelectionChanged ctx runSelection runModel)

                   treeViewSetModel treeView treeModel
                   treeViewSetModel chronView chronModel
                   treeViewSetModel runView runModel
                   return ctx



newMainWindow :: MainM (GladeXML, VisualizeContext)
newMainWindow =
    do mainContext <- ask
       (xml, mainWindow) <- liftIO $ loadMainWindowXML
       ctx <- newCtx xml
       mainWindowOpened
       liftIO $ on mainWindow deleteEvent (liftIO $ doMainWindowClosed mainContext)
       return (xml, ctx)
    where doMainWindowClosed mainContext = do runMain mainWindowClosed mainContext
                                              return True

milliToPicoseconds n = n * 1000000000

-- | Load the given log file in a background thread, displaying the
-- progress in the foreground thread.  When it's done, pop up a new
-- main window.
--
-- TODO: support displaying in an existing main window.
load :: FilePath -> MainM ()
load fn = do loadedFile <- liftIO $ do (xml, win)  <- loadLoadingProgressXML
                                       title       <- xmlGetWidget xml castToLabel "label_title"
                                       progressBar <- xmlGetWidget xml castToProgressBar "load_progress"
                                       status      <- xmlGetWidget xml castToLabel "label_statistics"
                                       -- Should be done in a separate thread but GHC/Gtk2HS
                                       -- suck for threaded GUI programming.  See
                                       --
                                       -- http://haskell.org/gtk2hs/archives/2005/07/24/writing-multi-threaded-guis/1/
                                       --
                                       -- for (very gory) details.
                                       labelSetText title ("Loading " ++ fn ++ "...")
                                       widgetShow win
                                       h   <- openFile fn ReadMode
                                       lastTime <- newIORef Nothing
                                       log <- loadLogFile h fn (showProgress progressBar lastTime)
                                       widgetDestroy win
                                       return log
             (xml, ctx) <- newMainWindow
             liftIO $ runVis (setLog loadedFile) ctx
             liftIO $ xmlGetWidget xml castToWindow "main_window" >>= widgetShowAll
             return ()
    where showProgress :: ProgressBar -> IORef (Maybe ClockTime) -> Integer -> Integer -> IO ()
          showProgress pb lastTime cur max =
              do oldf     <- progressBarGetFraction pb
                 currTime <- getClockTime
                 last     <- readIORef lastTime
                 writeIORef lastTime (Just currTime)
                 let updateInterval = TimeDiff { tdYear = 0,
                                                 tdMonth = 0,
                                                 tdDay = 0,
                                                 tdHour = 0,
                                                 tdMin = 0,
                                                 tdSec = 0,
                                                 tdPicosec = milliToPicoseconds 100 }
                     newf           = if max == 0 then 0 else ((fromInteger cur) / (fromInteger max))
                     longUpdate     = case last of
                                        Nothing -> True
                                        Just time -> diffClockTimes currTime time >= updateInterval
                     shouldUpdate   = longUpdate || newf == 1
                 when shouldUpdate (do progressBarSetFraction pb newf
                                       progressBarSetText pb (showFFloat (Just 1) (100 * newf) "" ++ "%")
                                       while (mainContextIteration mainContextDefault False) (return ()) ()
                                       return ())

main :: IO ()
main = do -- Gtk2Hs whines loudly if it gets loaded into a threaded
          -- runtime, but runhaskell always loads a threaded runtime,
          -- so we have to call this to be a script:
          unsafeInitGUIForThreadedRTS
          mainWindows <- newIORef 0
          mainLoop <- mainLoopNew Nothing False
          let mainLoopContext = MainLoopContext { numMainWindows = mainWindows,
                                                  mainLoop = mainLoop }
          args <- getArgs
          case args of
            [] -> do (xml, ctx) <- runMain newMainWindow mainLoopContext
                     mainWin <- xmlGetWidget xml castToWindow "main_window"
                     widgetShow (toWidget mainWin)
            [filename] -> runMain (load filename) mainLoopContext
            otherwise -> error "Too many arguments; expected at most one (the log file to load)."
          mainLoopRun mainLoop
