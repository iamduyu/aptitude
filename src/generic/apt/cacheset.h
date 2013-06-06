// -*- mode: c++ -*-
// Interfaces for handling sets of APT objects.
//
// Copyright (C) 2013  Daniel Hartwig
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

/* A minimal adaptor for APTs cacheset module that enables building
   and handling sets of APT objects in a standardized way. */

#ifndef APTITUDE_APT_CACHESET_H
#define APTITUDE_APT_CACHESET_H

#include <apt-pkg/cachefile.h>
#include <apt-pkg/cacheset.h>

namespace aptitude
{
namespace apt
{

class CacheSetHelper : public APT::CacheSetHelper
{
public:
  virtual void showPatternSelection(pkgCache::PkgIterator const &Pkg,
                                    std::string const &pattern);

  virtual void canNotFindPattern(APT::PackageContainerInterface * const pci,
                                 pkgCacheFile &Cache,
                                 std::string pattern);

  CacheSetHelper(bool const ShowErrors = true,
                 GlobalError::MsgType const &ErrorType = GlobalError::NOTICE)
    : APT::CacheSetHelper(ShowErrors, ErrorType) {}
};

class PackageContainerInterface : public APT::PackageContainerInterface
{
public:
  enum AptitudeConstructor { PATTERN = TASK + 16 };

  /** \brief Fill a package container using the given pattern.
   *
   *  This does not try any string as a search pattern, only those
   *  which contain explicit search terms or regex characters.
   */
  static bool FromPattern(APT::PackageContainerInterface * const pci,
                          pkgCacheFile &Cache,
                          std::string pattern,
                          CacheSetHelper &helper);

  /** \brief Fill a package container using the given string.  If the
   *  string names exactly a package then insert that package,
   *  otherwise, if the string is a search pattern, add all matching
   *  packages.
   */
  static bool FromString(APT::PackageContainerInterface * const pci,
                         pkgCacheFile &Cache,
                         std::string const &pattern,
                         CacheSetHelper &helper);

  static bool FromCommandLine(APT::PackageContainerInterface * const pci,
                              pkgCacheFile &Cache,
                              const char **cmdline,
                              CacheSetHelper &helper);
};

class VersionContainerInterface : public APT::VersionContainerInterface
{
public:
  static bool FromString(APT::VersionContainerInterface * const vci,
                         pkgCacheFile &Cache,
                         std::string pkg,
                         APT::VersionContainerInterface::Version const &fallback,
                         CacheSetHelper &helper,
                         bool const onlyFromName = false);

  static bool FromCommandLine(APT::VersionContainerInterface * const vci,
                              pkgCacheFile &Cache,
                              const char **cmdline,
                              APT::VersionContainerInterface::Version const &fallback,
                              CacheSetHelper &helper);
};

} /* namespace apt */
} /* namespace aptitude */

#endif
