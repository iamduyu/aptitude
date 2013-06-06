// -*- mode: c++ -*-
// Routines for handling sets of APT objects.
//
// Copyright (C) 2010, 2011, 2012, 2013  David Kalnischkies
// Copyright (C) 2014  Daniel Hartwig
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

/* Heavily based on the routines in apt-pkg/cacheset.cc, these
   routines primarily construct the APT cacheset objects with
   sensitivity to aptitudes features (such as pattern matching). */

/* TODO: This reimplements some routines from APT with only minor
   modifications to insert the aptitude specific handling.  With some
   modification to the interface on the APT side it will be possible
   to avoid such duplication.

   Bug: #686221 */

#include "cacheset.h"

#include "apt.h"
#include "aptitude.h"
#include "matching/match.h"
#include "matching/parse.h"

#include <cwidget/generic/util/transcode.h>

#include <apt-pkg/cachefile.h>
#include <apt-pkg/cacheset.h>
#include <apt-pkg/pkgsystem.h>

namespace aptitude
{
namespace apt
{
void CacheSetHelper::showPatternSelection(pkgCache::PkgIterator const &Pkg,
                                          std::string const &pattern)
{
}

void CacheSetHelper::canNotFindPattern(APT::PackageContainerInterface * const pci,
                                       pkgCacheFile &Cache,
                                       std::string pattern)
{
  if (ShowError == true)
    _error->Insert(ErrorType,
                   _("Couldn't find any package by pattern '%s'"),
                   pattern.c_str());
}

bool PackageContainerInterface::FromPattern(APT::PackageContainerInterface * const pci,
                                            pkgCacheFile &Cache,
                                            std::string pattern,
                                            CacheSetHelper &helper)
{
  namespace m = aptitude::matching;
  using cwidget::util::ref_ptr;

  typedef std::vector<std::pair<pkgCache::GrpIterator, ref_ptr<m::structural_match> > >
    result_list;

  if (m::is_pattern(pattern) == false)
    return false;

  const bool was_empty = pci->empty();
  if(was_empty == true)
    pci->setConstructor(static_cast<apt::PackageContainerInterface::Constructor>(PATTERN));

  size_t archfound = pattern.find_last_of(':');
  std::string arch = "native";
  if (archfound != std::string::npos)
    {
      arch = pattern.substr(archfound + 1);
      if (m::is_pattern(arch) == false)
        pattern.erase(archfound);
      else
        arch = "native";
    }

  ref_ptr<m::pattern> p(m::parse(pattern));
  if (p.valid() == false)
    return false;

  result_list matches;
  ref_ptr<m::search_cache> search_info(m::search_cache::create());
  /* Using 'search_groups' is perhaps faster than calling 'get_match'
     on every Group as the former may be able to use Xapian to limit
     the query set. */
  m::search_groups(p,
                   search_info,
                   matches,
                   *apt_cache_file,
                   *apt_package_records);

  bool found = false;
  for (result_list::const_iterator I = matches.begin();
       I != matches.end(); ++I)
    {
      pkgCache::PkgIterator Pkg = I->first.FindPkg(arch);
      if (Pkg.end() == true)
        {
          if (archfound == std::string::npos)
            Pkg = I->first.FindPreferredPkg();
          if (Pkg.end() == true)
            continue;
        }

      pci->insert(Pkg);
      helper.showPatternSelection(Pkg, pattern);
      found = true;
    }

  if (found == false)
    {
      helper.canNotFindPattern(pci, Cache, pattern);
      pci->setConstructor(PackageContainerInterface::UNKNOWN);
      return false;
    }

  if (was_empty == false &&
      (pci->getConstructor() != PackageContainerInterface::UNKNOWN))
    pci->setConstructor(PackageContainerInterface::UNKNOWN);

  return true;
}

bool PackageContainerInterface::FromString(APT::PackageContainerInterface * const pci,
                                           pkgCacheFile &Cache,
                                           std::string const &str,
                                           CacheSetHelper &helper)
{
  bool found = true;
  _error->PushToStack();

  /* TODO: Existing behaviour of aptitude is that most commands do not
     support bare regex.  Most apt commands do (using the FromRegex
     constructor here).  Support this in the future. */

  if(FromGroup(pci, Cache, str, helper) == false
     && FromTask(pci, Cache, str, helper) == false
     && FromPattern(pci, Cache, str, helper) == false)
    {
      helper.canNotFindPackage(pci, Cache, str);
      found = false;
    }

  if(found == true)
    _error->RevertToStack();
  else
    _error->MergeWithStack();
  return found;
}

bool PackageContainerInterface::FromCommandLine(APT::PackageContainerInterface * const pci,
                                                pkgCacheFile &Cache,
                                                const char **cmdline,
                                                CacheSetHelper &helper)
{
  bool found = false;
  for (const char **I = cmdline; *I != 0; ++I)
    found |= FromString(pci, Cache, *I, helper);
  return found;
}

bool VersionContainerInterface::FromString(APT::VersionContainerInterface * const vci,
                                           pkgCacheFile &Cache,
                                           std::string pkg,
                                           APT::VersionContainerInterface::Version const &fallback,
                                           CacheSetHelper &helper,
                                           bool const onlyFromName)
{
  std::string ver;
  bool verIsRel = false;
  size_t const vertag = pkg.find_last_of("/=");
  if (vertag != std::string::npos)
    {
      ver = pkg.substr(vertag + 1);
      verIsRel = (pkg[vertag] == '/');
      pkg.erase(vertag);
    }
  APT::PackageSet pkgset;
  if (onlyFromName == false)
    PackageContainerInterface::FromString(&pkgset, Cache, pkg, helper);
  else
    pkgset.insert(PackageContainerInterface::FromName(Cache, pkg, helper));

  bool errors = true;
  if (pkgset.getConstructor() != APT::PackageSet::UNKNOWN)
    errors = helper.showErrors(false);

  bool found = false;
  for (APT::PackageSet::const_iterator P = pkgset.begin();
       P != pkgset.end(); ++P)
    {
      if (vertag == std::string::npos)
        {
          found |= FromPackage(vci, Cache, P, fallback, helper);
          continue;
        }
      pkgCache::VerIterator V;
      if (ver == "installed")
        V = getInstalledVer(Cache, P, helper);
      else if (ver == "candidate")
        V = getCandidateVer(Cache, P, helper);
      else if (ver == "newest")
        {
          if (P->VersionList != 0)
            V = P.VersionList();
          else
            V = helper.canNotFindNewestVer(Cache, P);
        }
      else
        {
          const pkgVersionMatch::MatchType type = (verIsRel == true)
            ? pkgVersionMatch::Release
            : pkgVersionMatch::Version;
          pkgVersionMatch Match(ver, type);
          V = Match.Find(P);
          if (V.end() == true)
            {
              /* FIXME: Not an error presently. */
              if (verIsRel == true)
                _error->Error(_("Release '%s' for '%s' was not found"),
                              ver.c_str(), P.FullName(true).c_str());
              else
                _error->Error(_("Version '%s' for '%s' was not found"),
                              ver.c_str(), P.FullName(true).c_str());
              continue;
            }
        }
      if (V.end() == true)
        continue;
      helper.showSelectedVersion(P, V, ver, verIsRel);
      vci->insert(V);
      found = true;
    }

  if (pkgset.getConstructor() != APT::PackageSet::UNKNOWN)
    helper.showErrors(errors);

  return found;
}

bool VersionContainerInterface::FromCommandLine(APT::VersionContainerInterface * const vci,
                                                pkgCacheFile &Cache,
                                                const char **cmdline,
                                                APT::VersionContainerInterface::Version const &fallback,
                                                CacheSetHelper &helper)
{
  bool found = false;
  for (const char **I = cmdline; *I != 0; ++I)
    found |= FromString(vci, Cache, *I, fallback, helper);
  return found;
}

} /* namespace apt */
} /* namespace aptitude */
