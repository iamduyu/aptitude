// solution_item.h                                   -*-c++-*-
//
//   Copyright (C) 2005, 2007 Daniel Burrows
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
//
// Tree items that represent the contents of a solution.

#ifndef SOLUTION_ITEM_H
#define SOLUTION_ITEM_H

#include "menu_redirect.h"

#include <sigc++/slot.h>

#include <generic/apt/aptitude_resolver_universe.h>

#include <generic/problemresolver/solution.h>

#include <cwidget/widgets/treeitem.h>

class fragment;

class solution_item : public vs_treeitem, public menu_redirect
{
public:
  const wchar_t *tag();

  const wchar_t *label();

  /** \return \b true if this item is rejected. */
  virtual bool is_rejected() = 0;

  /** \return \b true if this item is mandatory. */
  virtual bool is_mandatory() = 0;

  /** Reject this item. */
  virtual void reject() = 0;

  /** Cancel the rejection of this item. */
  virtual void unreject() = 0;

  /** Make this item mandatory. */
  virtual void mandate() = 0;

  /** Make this item not mandatory. */
  virtual void unmandate() = 0;

  void toggle_rejected()
  {
    if(!is_rejected())
      reject();
    else
      unreject();
  }

  void toggle_mandated()
  {
    if(!is_mandatory())
      mandate();
    else
      unmandate();
  }

  style get_normal_style();

  bool dispatch_key(const key &k, vs_tree *owner);

  // Menu redirections:
  bool resolver_toggle_approved();
  bool resolver_toggle_approved_enabled();
  bool resolver_toggle_rejected();
  bool resolver_toggle_rejected_enabled();
};

class solution_act_item : public solution_item
{
  aptitude_universe::version ver;
  aptitude_universe::dep d;

  /** A callback to be invoked with a fragment-based description of
   *  this item.
   */
  sigc::slot1<void, fragment *> set_short_description;

  /** A callback to be invoked with the dependency corresponding to this item. */
  sigc::slot1<void, aptitude_resolver_dep> set_active_dep;

  void do_highlighted_changed(bool highlighted);
public:

  /** Create a solution_act_item.
   *
   *  \param act the action that this item corresponds to
   *  \param _set_short_description a callback to be invoked with a
   *               brief description of this item when it is selected
   *  \param _set_active_dep a callback to be invoked with the dependency
   *               corresponding to this item when the item is selected
   */
  solution_act_item(const generic_solution<aptitude_universe>::action &act,
		    const sigc::slot1<void, fragment *> &_set_short_description,
		    const sigc::slot1<void, aptitude_resolver_dep> &_set_active_dep)
    :ver(act.ver),
     d(act.d),
     set_short_description(_set_short_description),
     set_active_dep(_set_active_dep)
  {
    highlighted_changed.connect(sigc::mem_fun(this, &solution_act_item::do_highlighted_changed));
  }

  bool is_rejected();

  bool is_mandatory();

  void reject();

  void unreject();

  void mandate();

  void unmandate();

  void show_target_info();

  aptitude_universe::version get_ver() const
  {
    return ver;
  }

  bool dispatch_key(const key &k, vs_tree *owner);

  void paint(vs_tree *win, int y, bool hierarchical, const style &st);


  // Menu redirections.
  bool view_target_enabled();
  bool view_target();
};

/** Like a solution_act_item, but the display doesn't include the
 *  descriptive verb ("install" or whatever).
 */
class solution_act_item_bare : public solution_act_item
{
public:
  solution_act_item_bare(const generic_solution<aptitude_universe>::action &act,
			 const sigc::slot1<void, fragment *> &set_short_description,
			 const sigc::slot1<void, aptitude_resolver_dep> &set_active_dep)
    :solution_act_item(act, set_short_description, set_active_dep)
  {
  }

  void paint(vs_tree *win, int y, bool hierarchical, const style &st);
};

/** A solution item corresponding to leaving a dependency unresolved. */
class solution_unresolved_item : public solution_item
{
  aptitude_universe::dep d;

  /** If \b true, then a brief explanation about what this item is
   *  (suitable for inclusion in a list of alternatives) will be
   *  displayed.
   */
  bool fully_explained;

  sigc::slot1<void, aptitude_resolver_dep> set_active_dep;

  void do_highlighted_changed(bool highlighted);
public:
  solution_unresolved_item(const aptitude_universe::dep &_d,
			   bool _fully_explained,
			   const sigc::slot1<void, aptitude_resolver_dep> &_set_active_dep)
    :d(_d), fully_explained(_fully_explained), set_active_dep(_set_active_dep)
  {
    highlighted_changed.connect(sigc::mem_fun(this, &solution_unresolved_item::do_highlighted_changed));
  }

  bool is_rejected();
  bool is_mandatory();
  void reject();
  void unreject();
  void mandate();
  void unmandate();

  void paint(vs_tree *win, int y, bool hierarchical, const style &st);
};


enum action_type {action_remove, action_keep, action_install,
		  action_downgrade, action_upgrade};


/** A simpler version of find_pkg_state that doesn't care about
 *  automaticness.  Provided here because it's used by the solution
 *  item and screen, but should probably migrate to generic/
 *  eventually.
 */
action_type analyze_action(const aptitude_universe::version &ver);

#endif
