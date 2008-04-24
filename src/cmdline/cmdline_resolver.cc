// cmdline_resolver.cc
//
//   Copyright (C) 2005-2008 Daniel Burrows
//
//   This program is free software; you can redistribute it and/or
//   modify it under the terms of the GNU General Public License as
//   published by the Free Software Foundation; either version 2 of
//   the License, or (at your option) any later version.
//
//   This program is distributed in the hope that it will be useful,
//   but WITHOUT ANY WARRANTY; without even the implied warranty of
//   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//   General Public License for more details.
//
//   You should have received a copy of the GNU General Public License
//   along with this program; see the file COPYING.  If not, write to
//   the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
//   Boston, MA 02111-1307, USA.

#include "cmdline_resolver.h"

#include "cmdline_action.h"
#include "cmdline_common.h"
#include "cmdline_prompt.h"
#include "cmdline_show.h"
#include "cmdline_show_broken.h"
#include "cmdline_spinner.h"
#include "cmdline_util.h"

#include <aptitude.h>
#include <solution_fragment.h>

#include <generic/apt/aptcache.h>
#include <generic/apt/aptitude_resolver_universe.h>
#include <generic/apt/config_signal.h>
#include <generic/apt/resolver_manager.h>

#include <generic/problemresolver/exceptions.h>
#include <generic/problemresolver/solution.h>

#include <generic/util/util.h>

#include <cwidget/fragment.h>
#include <cwidget/generic/util/ssprintf.h>

#include <apt-pkg/error.h>
#include <apt-pkg/strutl.h>

#include <iostream>
#include <fstream>
#include <sstream>

#include <algorithm>

using namespace std;

typedef generic_solution<aptitude_universe> aptitude_solution;

namespace cw = cwidget;

/** Generate a cw::fragment describing a solution as an ordered sequence
 *  of actions.
 */
static cw::fragment *solution_story(const aptitude_solution &s)
{
  std::vector<aptitude_solution::action> actions;
  for(imm::map<aptitude_universe::package, aptitude_solution::action>::const_iterator
	i = s.get_actions().begin(); i != s.get_actions().end(); ++i)
    actions.push_back(i->second);
  sort(actions.begin(), actions.end(), aptitude_solution::action_id_compare());


  vector<cw::fragment *> fragments;

  for(vector<aptitude_solution::action>::const_iterator i = actions.begin();
      i != actions.end(); ++i)
    fragments.push_back(cw::fragf("%ls%n -> %F%n",
			      dep_text(i->d.get_dep()).c_str(),
			      indentbox(0, 4, action_fragment(*i))));

  return cw::sequence_fragment(fragments);
}

void cmdline_dump_resolver()
{
  string dumpfile = aptcfg->Find(PACKAGE "::CmdLine::Resolver-Dump", "");
  if(!dumpfile.empty())
    {
      ofstream f(dumpfile.c_str());
      if(!f)
	_error->Errno("dump_resolver", _("Unable to open %s for writing"), dumpfile.c_str());
      else
	{
	  resman->dump(f);

	  if(!f)
	    _error->Errno("dump_resolver", _("Error writing resolver state to %s"), dumpfile.c_str());
	  else
	    cout << _("Resolver state successfully written!");
	}
    }
}

static void setup_resolver(pkgset &to_install,
			   pkgset &to_hold,
			   pkgset &to_remove,
			   pkgset &to_purge,
			   bool force_no_change)
{
  if(!resman->resolver_exists())
    return;

  // Make sure the resolver is in the initial state so we can twiddle
  // it.
  resman->reset_resolver();

  resman->set_debug(aptcfg->FindB(PACKAGE "::CmdLine::Resolver-Debug", false));

  // For all packages that the user listed on the command-line (i.e.,
  // all in to_install, to_hold, to_remove, and to_purge), tell the
  // resolver to try *really really hard* to avoid altering their
  // state.
  if(force_no_change && resman->resolver_exists())
    {
      pkgset *sets[4]={&to_install, &to_hold, &to_remove, &to_purge};
      int tweak_amt=aptcfg->FindI(PACKAGE "::CmdLine::Request-Strictness", 10000);

      for(int i=0; i<4; ++i)
	{
	  pkgset &S=*sets[i];

	  for(pkgset::const_iterator p=S.begin();
	      p!=S.end(); ++p)
	    {
	      pkgDepCache::StateCache &state=(*apt_cache_file)[*p];
	      pkgCache::VerIterator instver=state.InstVerIter(*apt_cache_file);

	      for(pkgCache::VerIterator v=p->VersionList();
		  !v.end(); ++v)
		if(instver == v)
		  resman->tweak_score(*p, v,
				     tweak_amt);

	      if(instver.end())
		resman->tweak_score(*p, pkgCache::VerIterator(*apt_cache_file),
				   tweak_amt);
	    }
	}
    }

  cmdline_dump_resolver();
}

static inline cw::fragment *flowindentbox(int i1, int irest, cw::fragment *f)
{
  return indentbox(i1, irest, flowbox(f));
}

static void resolver_help(ostream &out)
{
  cw::fragment *f=indentbox(2, 2,
			cw::fragf(_("y: %F"
				"n: %F"
				"q: %F"
				",: %F"
				".: %F"
				"o: %F"
				"e: %F"
				"x: %F"
				"r pkg ver ...: %F%n"
				"a pkg ver ...: %F%n"
				"<ACTION> pkg... : %F%n"
				"%F"
				"%F"
				"%F"
				"%F"
				"%F"
				"%F"
				"%F"
				"%F"),
			      flowindentbox(0, 3,
					    cw::fragf(_("accept the proposed changes"))),
			      flowindentbox(0, 3,
					    cw::fragf(_("reject the proposed changes and search for another solution"))),
			      flowindentbox(0, 3,
					    cw::fragf(_("give up and quit the program"))),
			      flowindentbox(0, 3,
					    cw::fragf(_("move to the next solution"))),
			      flowindentbox(0, 3,
					    cw::fragf(_("move to the previous solution"))),
			      flowindentbox(0, 3,
					    cw::fragf(_("toggle between the contents of the solution and an explanation of the solution"))),
			      flowindentbox(0, 3,
					    cw::fragf(_("examine the solution in the visual user interface"))),
			      flowindentbox(0, 3,
					    cw::fragf(_("abort automatic dependency resolution; resolve dependencies by hand instead"))),
			      flowindentbox(0, 15,
					    cw::fragf(_("reject the given package versions; don't display any solutions in which they occur.  Enter UNINST instead of a version to reject removing the package."))),
			      flowindentbox(0, 15,
							// ForTranslators: "(;" is ...???? A smiley?
					    cw::fragf(_("accept the given package versions (; display only solutions in which they occur.  Enter UNINST instead of a version to accept removing the package."))),
			      flowindentbox(0, 3,
					    cw::fragf(_("adjust the state of the listed packages, where ACTION is one of:"))),
			      flowindentbox(0, 4,
					    cw::fragf(_("'+' to install packages"))),
			      flowindentbox(0, 5,
					    cw::fragf(_("'+M' to install packages and immediately flag them as automatically installed"))),
			      flowindentbox(0, 4,
					    cw::fragf(_("'-' to remove packages"))),
			      flowindentbox(0, 4,
					    cw::fragf(_("'_' to purge packages"))),
			      flowindentbox(0, 4,
					    cw::fragf(_("'=' to place packages on hold"))),
			      flowindentbox(0, 4,
					    cw::fragf(_("':' to keep packages in their current state without placing them on hold"))),
			      flowindentbox(0, 4,
					    cw::fragf(_("'&M' to mark packages as automatically installed"))),
			      flowindentbox(0, 4,
					    cw::fragf(_("'&m' to mark packages as manually installed"))),
			      flowindentbox(0, 3,
					    cw::fragf(_("Adjustments will cause the current solution to be discarded and recalculated as necessary.")))));

  out << f->layout(screen_width, screen_width, cwidget::style());
  delete f;
}

// Given several versions with the same VerStr, choose one to output.
static pkgCache::VerIterator choose_version(const vector<pkgCache::VerIterator> &choices)
{
  eassert(!choices.empty());

  if(choices.size() == 1)
    return choices.front();

  cout << ssprintf(_("The version %s is available in the following archives:"), choices.front().VerStr()) << endl;

  for(vector<pkgCache::VerIterator>::size_type i = 0;
      i < choices.size(); ++i)
    cout << ssprintf(" (%d) %s", i+1, archives_text(choices[i]).c_str()) << endl;

  while(1)
    {
      string response = prompt_string(ssprintf(_("Select the version of %s that should be used: "), choices.front().ParentPkg().Name()));

      int i;
      istringstream in(response);
      in >> ws >> i >> ws;

      if(!in || !in.eof() || i < 1 || i > choices.size())
	cerr << ssprintf(_("Invalid response.  Please enter an integer between 1 and %d."), choices.size()) << endl;
      else
	return choices[i];
    }
}

static void reject_or_mandate_version(const string &s,
				      bool is_reject)
{
  istringstream in(s);

  in >> ws;

  if(in.eof())
    {
      cerr << ssprintf(_("Expected at least one package/version pair following '%c'"),
			 is_reject ? 'R' : 'A') << endl;
      return;
    }

  string pkgname;
  string vername;

  while(!in.eof())
    {
      in >> pkgname >> ws;

      if(in.eof())
	{
	  cerr << ssprintf(_("Expected a version or \"%s\" after \"%s\""), "UNINST", pkgname.c_str()) << endl;
	  return;
	}

      in >> vername >> ws;

      pkgCache::PkgIterator pkg((*apt_cache_file)->FindPkg(pkgname));

      if(pkg.end())
	{
	  cerr << ssprintf(_("No such package \"%s\""), pkgname.c_str()) << endl;
	  continue;
	}

      aptitude_universe::version ver(pkg,
				     pkgCache::VerIterator(*apt_cache_file),
				     *apt_cache_file);
      if(stringcasecmp(vername, "UNINST") != 0)
	{
	  vector<pkgCache::VerIterator> found;
	  for(pkgCache::VerIterator vi = pkg.VersionList(); !vi.end(); ++vi)
	    if(vi.VerStr() == vername)
	      found.push_back(vi);

	  if(found.empty())
	    {
	      cerr << ssprintf(_("%s has no version named \"%s\""),
			       pkgname.c_str(), vername.c_str()) << endl;
	      continue;
	    }

	  ver = aptitude_universe::version(pkg, choose_version(found),
					   *apt_cache_file);

	  eassert(!ver.get_ver().end());
	  eassert(ver.get_pkg() == ver.get_ver().ParentPkg());
	}

      if(is_reject)
	{
	  if(resman->is_rejected(ver))
	    {
	      if(ver.get_ver().end())
		cout << ssprintf(_("Allowing the removal of %s"),
				 pkgname.c_str()) << endl;
	      else
		cout << ssprintf(_("Allowing the installation of %s version %s (%s)"),
				 pkg.Name(),
				 ver.get_ver().VerStr(),
				 archives_text(ver.get_ver()).c_str()) << endl;

	      resman->unreject_version(ver);
	    }
	  else
	    {
	      if(ver.get_ver().end())
		cout << ssprintf(_("Rejecting the removal of %s"),
				 pkgname.c_str()) << endl;
	      else
		cout << ssprintf(_("Rejecting the installation of %s version %s (%s)"),
				 pkg.Name(),
				 ver.get_ver().VerStr(),
				 archives_text(ver.get_ver()).c_str()) << endl;

	      resman->reject_version(ver);
	    }
	}
      else
	{
	  if(resman->is_mandatory(ver))
	    {
	      if(ver.get_ver().end())
		cout << ssprintf(_("No longer requiring the removal of %s"),
				 pkgname.c_str()) << endl;
	      else
		cout << ssprintf(_("No longer requiring the installation of %s version %s (%s)"),
				 pkg.Name(), ver.get_ver().VerStr(),
				 archives_text(ver.get_ver()).c_str()) << endl;

	      resman->unmandate_version(ver);
	    }
	  else
	    {
	      if(ver.get_ver().end())
		cout << ssprintf(_("Requiring the removal of %s"),
				 pkgname.c_str()) << endl;
	      else
		cout << ssprintf(_("Requiring the installation of %s version %s (%s)"),
				 pkg.Name(), ver.get_ver().VerStr(),
				 archives_text(ver.get_ver()).c_str()) << endl;

	      resman->mandate_version(ver);
	    }
	}
    }
}

// TODO: make this generic?
class cmdline_resolver_continuation : public resolver_manager::background_continuation
{
public:
  struct resolver_result
  {
    /** If \b true, then NoMoreSolutions was thrown. */
    bool out_of_solutions;

    /** If \b true, then NoMoreTime was thrown. */
    bool out_of_time;

    /** If \b true, then we got a fatal exception. */
    bool aborted;

    /** If aborted is \b true, then this is the message associated
     *  with the deadly exception.
     */
    std::string abort_msg;

    /** If out_of_solutions, out_of_time, and aborted are \b false,
    this is * the result returned by the resolver.
     */
    aptitude_solution sol;

    resolver_result()
      : out_of_solutions(false), out_of_time(false)
    {
    }

  private:
    resolver_result(bool _out_of_solutions,
		    bool _out_of_time,
		    bool _aborted,
		    std::string _abort_msg,
		    const aptitude_solution &_sol)
      : out_of_solutions(_out_of_solutions),
	out_of_time(_out_of_time),
	aborted(_aborted),
	abort_msg(_abort_msg),
	sol(_sol)
    {
    }

  public:
    static resolver_result OutOfSolutions()
    {
      return resolver_result(true, false, false, "", aptitude_solution());
    }

    static resolver_result OutOfTime()
    {
      return resolver_result(false, true, false, "", aptitude_solution());
    }

    static resolver_result Aborted(const std::string &msg)
    {
      return resolver_result(false, false, true, msg, aptitude_solution());
    }

    static resolver_result Success(const aptitude_solution &sol)
    {
      return resolver_result(false, false, false, "", sol);
    }
  };

private:
  cwidget::threads::box<resolver_result> &retbox;

public:
  cmdline_resolver_continuation(cwidget::threads::box<resolver_result> &_retbox)
    : retbox(_retbox)
  {
  }

  void success(const aptitude_solution &sol)
  {
    retbox.put(resolver_result::Success(sol));
  }

  void no_more_solutions()
  {
    retbox.put(resolver_result::OutOfSolutions());
  }

  void no_more_time()
  {
    retbox.put(resolver_result::OutOfTime());
  }

  void interrupted()
  {
    abort();
  }

  void aborted(const cwidget::util::Exception &e)
  {
    retbox.put(resolver_result::Aborted(e.errmsg()));
  }
};

class CmdlineSearchAbortedException : public cwidget::util::Exception
{
  std::string msg;

public:
  CmdlineSearchAbortedException(const std::string &_msg)
    : msg(_msg)
  {
  }

  std::string errmsg() const { return msg; }
};

class CmdlineSearchDisabledException : public cwidget::util::Exception
{
  std::string msg;

public:
  CmdlineSearchDisabledException(const std::string &_msg)
    : msg(_msg)
  {
  }

  std::string errmsg() const { return msg; }
};

aptitude_solution calculate_current_solution(bool suppress_message)
{
  const int step_limit = aptcfg->FindI(PACKAGE "::ProblemResolver::StepLimit", 5000);
  if(step_limit <= 0)
    {
      const std::string msg = ssprintf(_("Would resolve dependencies, but dependency resolution is disabled.\n   (%s::ProblemResolver::StepLimit = 0)\n"), PACKAGE);

      // It's important that the code path leading to here doesn't
      // access resman: the resolver won't exist in this case.
      throw CmdlineSearchDisabledException(msg);
    }

  if(!resman->resolver_exists())
    {
      const std::string msg = _("I want to resolve dependencies, but no dependency resolver was created.");

      throw CmdlineSearchAbortedException(msg);
    }



  if(resman->get_selected_solution() < resman->generated_solution_count())
    return resman->get_solution(resman->get_selected_solution(), 0);


  cmdline_spinner spin(aptcfg->FindI("Quiet", 0));

  if(!suppress_message)
    std::cout << _("Resolving dependencies...") << std::endl;

  cwidget::threads::box<cmdline_resolver_continuation::resolver_result> retbox;

  resman->get_solution_background(resman->generated_solution_count(),
				  step_limit,
				  new cmdline_resolver_continuation(retbox));

  cmdline_resolver_continuation::resolver_result res;
  bool done = false;
  // The number of milliseconds to step per display.
  long spin_step = aptcfg->FindI(PACKAGE "::Spin-Interval", 500);

  do
    {
      timeval until;
      gettimeofday(&until, 0);

      until.tv_usec += spin_step * 1000L;
      until.tv_sec += until.tv_usec / (1000L * 1000L);
      until.tv_usec = until.tv_usec % (1000L * 1000L);

      timespec until_ts;
      until_ts.tv_sec = until.tv_sec;
      until_ts.tv_nsec = until.tv_usec * 1000;

      done = retbox.timed_take(res, until_ts);

      if(!done)
	{
	  resolver_manager::state state = resman->state_snapshot();

	  spin.set_msg(ssprintf(_("open: %d; closed: %d; defer: %d; conflict: %d"),
				state.open_size, state.closed_size,
				state.deferred_size, state.conflicts_size));
	  spin.display();
	  spin.tick();
	}
    } while(!done);

  if(res.out_of_time)
    throw NoMoreTime();
  else if(res.out_of_solutions)
    throw NoMoreSolutions();
  else if(res.aborted)
    throw CmdlineSearchAbortedException(res.abort_msg);
  else
    return res.sol;
}

aptitude::cmdline::cmdline_resolver_result
cmdline_resolve_deps(pkgset &to_install,
		     pkgset &to_hold,
		     pkgset &to_remove,
		     pkgset &to_purge,
		     bool assume_yes,
		     bool force_no_change,
		     int verbose,
		     pkgPolicy &policy,
		     bool arch_only)
{
  bool story_is_default = aptcfg->FindB(PACKAGE "::CmdLine::Resolver-Show-Steps", false);

  while(!show_broken())
    {
      setup_resolver(to_install, to_hold, to_remove, to_purge,
		     force_no_change);
      aptitude_solution lastsol;

      // The inner loop tries to generate solutions until some
      // packages are modified by the user (then the new set of broken
      // packages, if any, is displayed and we start over)
      bool modified_pkgs=false;
      while(!modified_pkgs)
	try
	  {
	    try
	      {
		aptitude_solution sol = calculate_current_solution(true);

		if(_error->PendingError())
		  _error->DumpErrors();

		if(sol != lastsol)
		  {
		    cw::fragment *f=cw::sequence_fragment(flowbox(cwidget::text_fragment(_("The following actions will resolve these dependencies:"))),
						  cwidget::newline_fragment(),
						  story_is_default
						    ? solution_story(sol)
						    : solution_fragment(sol),
						  NULL);

		    update_screen_width();

		    cwidget::fragment_contents lines=f->layout(screen_width, screen_width, cwidget::style());

		    delete f;

		    cout << lines << endl;
		    lastsol=sol;
		  }

		string response=assume_yes?"Y":prompt_string(_("Accept this solution? [Y/n/q/?] "));

		string::size_type loc=0;
		while(loc<response.size() && isspace(response[loc]))
		  ++loc;
		if(loc == response.size())
		  {
		    response='Y';
		    loc=0;
		  }

		switch(toupper(response[loc]))
		  {
		  case 'Y':
		    (*apt_cache_file)->apply_solution(calculate_current_solution(true), NULL);
		    modified_pkgs=true;
		    break;
		  case 'N':
		    {
		      int curr_count = resman->generated_solution_count();

		      if(curr_count>0)
			while(resman->get_selected_solution() < curr_count)
			  resman->select_next_solution();
		    }
		    break;
		  case 'Q':
		    cout << _("Abandoning all efforts to resolve these dependencies.") << endl;
		    return aptitude::cmdline::resolver_user_exit;
		  case 'X':
		    cout << _("Abandoning automatic dependency resolution and reverting to manual resolution.") << endl;
		    return aptitude::cmdline::resolver_incomplete;
		  case 'O':
		    {
		      story_is_default = !story_is_default;
		      cw::fragment *f = story_is_default
			              ? solution_story(sol)
			              : solution_fragment(sol);
		      update_screen_width();
		      cout << f->layout(screen_width, screen_width,
					cwidget::style()) << endl;
		      delete f;
		      break;
		    }
		  case 'E':
		    ui_solution_screen();
		    break;
		  case 'R':
		    reject_or_mandate_version(string(response, 1), true);
		    break;
		  case 'A':
		    reject_or_mandate_version(string(response, 1), false);
		    break;
		  case '.':
		    resman->select_next_solution();
		    break;
		  case ',':
		    resman->select_previous_solution();
		    break;
		  case '?':
		    cout << _("The following commands are available:") << endl;
		    resolver_help(cout);
		    break;
		  case '+':
		  case '-':
		  case '=':
		  case '_':
		  case ':':
		    {
		      std::set<pkgCache::PkgIterator> seen_virtual_packages;
		      cmdline_parse_action(response, seen_virtual_packages,
					   to_install, to_hold,
					   to_remove, to_purge, verbose,
					   policy, arch_only, false);
		      modified_pkgs=true;
		    }
		    break;
		    // Undocumented debug feature:
		  case '~':
		    {
		      string fn=prompt_string(_("File to write resolver state to: "));
		      ofstream f(fn.c_str());
		      if(!f)
			_error->Errno("dump_resolver", _("Unable to open %s for writing"), fn.c_str());
		      else
			{
			  resman->dump(f);
			  if(!f)
			    _error->Errno("dump_resolver", _("Error writing resolver state to %s"), fn.c_str());
			  else
			    cout << _("Resolver state successfully written!");
			}
		    }
		    break;
		  default:
		    cout << _("Invalid response; please enter one of the following commands:") << endl;
		    resolver_help(cout);
		    break;
		  }
	      }
	    catch(NoMoreTime)
	      {
		bool done=false;
		while(!done)
		  {
		    string response;
// FIXME: translate Y, N
		    if(!assume_yes)
		      response = prompt_string(_("No solution found within the allotted time.  Try harder? [Y/n]"));

		    string::size_type loc=0;
		    while(loc<response.size() && isspace(response[loc]))
		      ++loc;
		    if(loc == response.size())
		      {
			loc=0;
			response='Y';
		      }
// FIXME: translate Y, N
		    switch(toupper(response[loc]))
		      {
		      case 'Y':
			try
			  {
			    calculate_current_solution(false);
			    done=true;
			  }
			catch(NoMoreTime)
			  {
			    // ignore and continue looping.
			  }
			// NoMoreSolutions flows to the outer catch.
			break;
		      case 'N':
			cout << _("Abandoning all efforts to resolve these dependencies.") << endl;
			return aptitude::cmdline::resolver_incomplete;
		      default:
			cout << _("Invalid response; please enter 'y' or 'n'.") << endl;
		      }
		  }
	      }
	  }
	catch(NoMoreSolutions)
	  {
	    if(resman->generated_solution_count()==0)
	      {
		cout << _("Unable to resolve dependencies!  Giving up...") << endl;
		return aptitude::cmdline::resolver_incomplete;
	      }
	    else
	      {
		cout << endl
		     << _("*** No more solutions available ***")
		     << endl
		     << endl;
		// Force it to re-print the last solution.
		resman->select_previous_solution();
		lastsol.nullify();
	      }
	  }
	catch(StdinEOFException)
	  {
	    throw;
	  }
	catch(const CmdlineSearchDisabledException &e)
	  {
	    cout << e.errmsg();
	    return aptitude::cmdline::resolver_incomplete;
	  }
	catch(cwidget::util::Exception &e)
	  {
	    cout << _("*** ERROR: search aborted by fatal exception.  You may continue\n           searching, but some solutions will be unreachable.")
		 << endl
		 << endl
		 << e.errmsg();

	    if(resman->generated_solution_count() == 0)
	      return aptitude::cmdline::resolver_incomplete;
	    else
	      {
		cout << endl << endl;

		// Force it to re-print the last solution.
		if(resman->get_selected_solution() == resman->generated_solution_count())
		  resman->select_previous_solution();
		lastsol.nullify();
	      }
	  }
    }

  return aptitude::cmdline::resolver_success;
}


namespace aptitude
{
  namespace cmdline
  {
    namespace
    {
      // Set up aptitude's internal resolver for 'safe' resolution.
      // Essentialy this means (1) forbid it from removing any package,
      // and (2) only install the default candidate version of a package
      // or the current version.
      void setup_safe_resolver(bool no_new_installs, bool no_new_upgrades)
      {
	if(!resman->resolver_exists())
	  return;

	resman->reset_resolver();

	resman->set_debug(aptcfg->FindB(PACKAGE "::CmdLine::Resolver-Debug", false));

	for(pkgCache::PkgIterator p = (*apt_cache_file)->PkgBegin();
	    !p.end(); ++p)
	  {
	    // Forbid the resolver from removing installed packages.
	    if(!p.CurrentVer().end())
	      {
		aptitude_resolver_version
		  remove_p(p,
			   pkgCache::VerIterator(*apt_cache_file),
			   *apt_cache_file);

		resman->reject_version(remove_p);
	      }

	    // Forbid all real versions that aren't the current version or
	    // the candidate version.
	    for(pkgCache::VerIterator v = p.VersionList();
		!v.end(); ++v)
	      {
		// For our purposes, all half-unpacked etc states are
		// installed.
		const bool p_is_installed =
		  p->CurrentState != pkgCache::State::NotInstalled &&
		  p->CurrentState != pkgCache::State::ConfigFiles;

		const bool p_will_install =
		  (*apt_cache_file)[p].Install();

		if(v != p.CurrentVer() &&
		   // Disallow installing not-installed packages that
		   // aren't marked for installation if
		   // no_new_installs is set.
		   ((!p_is_installed && !p_will_install && no_new_installs) ||
		    (p_is_installed && p_will_install && no_new_upgrades) ||
		    v != (*apt_cache_file)[p].CandidateVerIter(*apt_cache_file)))
		  {
		    aptitude_resolver_version
		      p_v(p, v, *apt_cache_file);
		    resman->reject_version(p_v);
		  }
	      }
	  }

	cmdline_dump_resolver();
      }
    }

    // Take the first solution we can compute, returning false if we
    // failed to find a solution.
    bool safe_resolve_deps(int verbose, bool no_new_installs, bool no_new_upgrades)
    {
      if(!resman->resolver_exists())
	return true;

      const bool debug = aptcfg->FindB(PACKAGE "::CmdLine::Resolver-Debug", false);

      setup_safe_resolver(no_new_installs, no_new_upgrades);

      generic_solution<aptitude_universe> last_sol;
      try
	{
	  generic_solution<aptitude_universe> sol = calculate_current_solution(true);
	  last_sol = sol;
	  bool first = true;
	  typedef imm::map<aptitude_resolver_package,
	    generic_solution<aptitude_universe>::action> actions_map;
	  while(!(!first &&
		  last_sol &&
		  sol.get_actions() == last_sol.get_actions() &&
		  sol.get_unresolved_soft_deps() == last_sol.get_unresolved_soft_deps()))
	    {
	      first = false;
	      // Mandate all the upgrades and installs in this solution,
	      // then ask for the next solution.  The goal is to try to
	      // find the best solution, not just some solution, but to
	      // preserve our previous decisions in order to avoid
	      // thrashing around between alternatives.
	      for(actions_map::const_iterator it = sol.get_actions().begin();
		  it != sol.get_actions().end(); ++it)
		{
		  if(it->second.ver.get_ver() != it->second.ver.get_pkg().CurrentVer())
		    {
		      if(debug)
			std::cout << "Mandating the upgrade or install " << it->second.ver
				  << ", since it was produced as part of a solution."
				  << std::endl;
		      resman->mandate_version(it->second.ver);
		    }
		  else
		    {
		      if(debug)
			std::cout << "Not mandating " << it->second.ver
				  << ", since it is a hold."
				  << std::endl;
		    }
		}
	      last_sol = sol;
	      resman->select_next_solution();
	      sol = calculate_current_solution(false);
	    }

	  // Internal error that should never happen, but try to survive
	  // if it does.
	  std::cout << "*** Internal error: the resolver unexpectedly produced the same result twice."
		    << std::endl
		    << "Previous iteration was:" << std::endl;
	  last_sol.dump(std::cout, true);
	  std::cout << std::endl << "Current iteration was:" << std::endl;
	  sol.dump(std::cout, true);
	  std::cout << std::endl;

	  (*apt_cache_file)->apply_solution(last_sol, NULL);
	}
      // If anything goes wrong, we give up (silently if verbosity is disabled).
      catch(NoMoreTime)
	{
	  if(last_sol)
	    {
	      std::cout << _("The resolver timed out after producing a solution; some possible upgrades might not be performed.");
	      (*apt_cache_file)->apply_solution(last_sol, NULL);
	      return true;
	    }
	  else
	    {
	      if(verbose > 0)
		std::cout << _("Unable to resolve dependencies for the upgrade (the resolver timed out).");
	      return false;
	    }
	}
      catch(NoMoreSolutions)
	{
	  if(last_sol)
	    {
	      (*apt_cache_file)->apply_solution(last_sol, NULL);
	      return true;
	    }
	  else
	    {
	      if(verbose > 0)
		std::cout << _("Unable to resolve dependencies for the upgrade (no solution found).");
	      return false;
	    }
	}
      catch(const cw::util::Exception &e)
	{
	  if(last_sol)
	    {
	      (*apt_cache_file)->apply_solution(last_sol, NULL);
	      std::cout << cw::util::ssprintf(_("Dependency resolution incomplete (%s); some possible upgrades might not be performed."), e.errmsg().c_str());
	      return true;
	    }
	  else
	    {
	      if(verbose > 0)
		std::cout << cw::util::ssprintf(_("Unable to resolve dependencies for the upgrade (%s)."), e.errmsg().c_str());
	      return false;
	    }
	}

      return true;
    }
  }
}
