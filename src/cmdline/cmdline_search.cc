// cmdline_search.cc
//
//   Copyright 2004 Daniel Burrows

#include "cmdline_search.h"

#include "cmdline_common.h"
#include "cmdline_util.h"

#include <aptitude.h>
#include <load_sortpolicy.h>
#include <loggers.h>
#include <pkg_columnizer.h>
#include <pkg_item.h>
#include <pkg_sortpolicy.h>

#include <generic/apt/apt.h>
#include <generic/apt/matching/match.h>
#include <generic/apt/matching/parse.h>
#include <generic/apt/matching/pattern.h>

#include <cwidget/config/column_definition.h>
#include <cwidget/generic/util/transcode.h>

#include <apt-pkg/error.h>
#include <apt-pkg/strutl.h>

#include <algorithm>

#include <boost/scoped_ptr.hpp>

using namespace std;
namespace cw = cwidget;
using aptitude::Loggers;
using cwidget::util::ref_ptr;
using cwidget::util::transcode;
using namespace aptitude::matching;
using namespace cwidget::config;

namespace
{
  int do_search_packages(const std::vector<ref_ptr<pattern> > &patterns,
                         pkg_sortpolicy *sort_policy,
                         const column_definition_list &columns,
                         int format_width,
                         bool disable_columns,
                         bool debug)
  {
    typedef std::vector<std::pair<pkgCache::PkgIterator, ref_ptr<structural_match> > >
      results_list;

    results_list output;
    ref_ptr<search_cache> search_info(search_cache::create());
    for(std::vector<ref_ptr<pattern> >::const_iterator pIt = patterns.begin();
        pIt != patterns.end(); ++pIt)
      {
        // Q: should I just wrap an ?or around them all?
        aptitude::matching::search(*pIt,
                                   search_info,
                                   output,
                                   *apt_cache_file,
                                   *apt_package_records,
                                   debug);
      }

    _error->DumpErrors();

    std::sort(output.begin(), output.end(),
              aptitude::cmdline::package_results_lt(sort_policy));
    output.erase(std::unique(output.begin(), output.end(),
                             aptitude::cmdline::package_results_eq(sort_policy)),
                 output.end());

    for(results_list::const_iterator it = output.begin(); it != output.end(); ++it)
      {
        column_parameters *p =
          new aptitude::cmdline::search_result_column_parameters(it->second);
        pkg_item::pkg_columnizer columnizer(it->first,
                                            it->first.VersionList(),
                                            columns,
                                            0);
        if(disable_columns)
          printf("%ls\n", aptitude::cmdline::de_columnize(columns, columnizer, *p).c_str());
        else
          printf("%ls\n",
                 columnizer.layout_columns(format_width == -1 ? screen_width : format_width,
                                           *p).c_str());

        // Note that this deletes the whole result, so we can't re-use
        // the list.
        delete p;
      }

    return 0;
  }
}

// FIXME: apt-cache does lots of tricks to make this fast.  Should I?
int cmdline_search(int argc, char *argv[], const char *status_fname,
		   string display_format, string width, string sort,
		   bool disable_columns, bool debug)
{
  int real_width=-1;

  pkg_item::pkg_columnizer::setup_columns();

  pkg_sortpolicy *s=parse_sortpolicy(sort);

  if(!s)
    {
      _error->DumpErrors();
      return -1;
    }

  _error->DumpErrors();

  if(!width.empty())
    {
      unsigned long tmp=screen_width;
      StrToNum(width.c_str(), tmp, width.size());
      real_width=tmp;
    }

  wstring wdisplay_format;

  if(!cw::util::transcode(display_format.c_str(), wdisplay_format))
    {
      _error->DumpErrors();
      fprintf(stderr, _("iconv of %s failed.\n"), display_format.c_str());
      return -1;
    }

  boost::scoped_ptr<column_definition_list> columns;
  columns.reset(parse_columns(wdisplay_format,
                              pkg_item::pkg_columnizer::parse_column_type,
                              pkg_item::pkg_columnizer::defaults));

  if(columns.get() == NULL)
    {
      _error->DumpErrors();
      return -1;
    }

  if(argc<=1)
    {
      fprintf(stderr, _("search: You must provide at least one search term\n"));
      return -1;
    }

  OpProgress progress;

  apt_init(&progress, true, status_fname);

  if(_error->PendingError())
    {
      _error->DumpErrors();
      return -1;
    }

  vector<ref_ptr<pattern> > matchers;

  for(int i=1; i<argc; ++i)
    {
      const char * const arg = argv[i];

      ref_ptr<pattern> m = parse(arg);
      if(!m.valid())
        {
          _error->DumpErrors();

          return -1;
        }

      matchers.push_back(m);
    }

  return do_search_packages(matchers,
                            s,
                            *columns,
                            real_width,
                            disable_columns,
                            debug);
}
