// test_resolver_costs.cc
//
// Copyright (C) 2010 Daniel Burrows
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License as
// published by the Free Software Foundation; either version 2 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; see the file COPYING.  If not, write to
// the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
// Boston, MA 02111-1307, USA.

#include <generic/apt/aptitude_resolver_cost_settings.h>
#include <generic/apt/aptitude_resolver_cost_syntax.h>

#include <cppunit/extensions/HelperMacros.h>

#include <boost/lexical_cast.hpp>

class ResolverCostsTest : public CppUnit::TestFixture
{
  CPPUNIT_TEST_SUITE(ResolverCostsTest);

  CPPUNIT_TEST(testResolverCostSettingsAdditive);
  CPPUNIT_TEST(testResolverCostSettingsMaximized);
  CPPUNIT_TEST(testResolverCostSettingsMixed);
  CPPUNIT_TEST(testResolverCostSettingsMismatch);
  CPPUNIT_TEST(testResolverCostSettingsParse);
  CPPUNIT_TEST(testResolverCostSettingsParseFail);
  CPPUNIT_TEST(testResolverCostSettingsSerialize);

  CPPUNIT_TEST_SUITE_END();

public:
  void testResolverCostSettingsAdditive()
  {
    // Construct a settings object for:
    // removals+cancels, aardvarks, removals
    //
    // where "aardvarks" is flagged as additive (for extra fun).
    boost::shared_ptr<std::vector<cost_component_structure> > components =
      boost::make_shared<std::vector<cost_component_structure> >();

    std::vector<cost_component_structure::entry> c0;
    c0.push_back(cost_component_structure::entry("removals", 1));
    c0.push_back(cost_component_structure::entry("cancels", 2));

    std::vector<cost_component_structure::entry> c1;
    c1.push_back(cost_component_structure::entry("aardvarks", 1));

    std::vector<cost_component_structure::entry> c2;
    c2.push_back(cost_component_structure::entry("cancels", 1));

    components->push_back(cost_component_structure(cost_component_structure::combine_add, c0));
    components->push_back(cost_component_structure(cost_component_structure::combine_add, c1));
    components->push_back(cost_component_structure(cost_component_structure::combine_none, c2));


    aptitude_resolver_cost_settings settings(components);

    aptitude_resolver_cost_settings::component
      removals_component = settings.get_or_create_component("removals", aptitude_resolver_cost_settings::additive),
      cancels_component = settings.get_or_create_component("cancels", aptitude_resolver_cost_settings::additive),
      aardvarks_component = settings.get_or_create_component("aardvarks", aptitude_resolver_cost_settings::additive),
      nonexistent_component = settings.get_or_create_component("llamas", aptitude_resolver_cost_settings::additive);

    CPPUNIT_ASSERT_EQUAL(tier_operation::make_add_to_user_level(0, 4),
                         settings.add_to_cost(removals_component, 4));
    CPPUNIT_ASSERT_EQUAL(tier_operation::make_add_to_user_level(0, 2) +
                         tier_operation::make_add_to_user_level(2, 1),
                         settings.add_to_cost(cancels_component, 1));
    CPPUNIT_ASSERT_EQUAL(tier_operation::make_add_to_user_level(1, 5),
                         settings.add_to_cost(aardvarks_component, 5));
    CPPUNIT_ASSERT_EQUAL(tier_operation(),
                         settings.add_to_cost(nonexistent_component, 100));

    CPPUNIT_ASSERT(settings.is_component_relevant(removals_component));
    CPPUNIT_ASSERT(settings.is_component_relevant(cancels_component));
    CPPUNIT_ASSERT(settings.is_component_relevant(aardvarks_component));
    CPPUNIT_ASSERT(!settings.is_component_relevant(nonexistent_component));
  }

  void testResolverCostSettingsMaximized()
  {
    // Construct a settings object for:
    // max(removals, cancels), aardvarks, removals
    //
    // where "aardvarks" is flagged as maximized (for extra fun).
    boost::shared_ptr<std::vector<cost_component_structure> > components =
      boost::make_shared<std::vector<cost_component_structure> >();


    std::vector<cost_component_structure::entry> c0;
    c0.push_back(cost_component_structure::entry("removals", 1));
    c0.push_back(cost_component_structure::entry("cancels", 2));

    std::vector<cost_component_structure::entry> c1;
    c1.push_back(cost_component_structure::entry("aardvarks", 1));

    std::vector<cost_component_structure::entry> c2;
    c2.push_back(cost_component_structure::entry("cancels", 1));

    components->push_back(cost_component_structure(cost_component_structure::combine_max, c0));
    components->push_back(cost_component_structure(cost_component_structure::combine_max, c1));
    components->push_back(cost_component_structure(cost_component_structure::combine_none, c2));


    aptitude_resolver_cost_settings settings(components);

    aptitude_resolver_cost_settings::component
      removals_component = settings.get_or_create_component("removals", aptitude_resolver_cost_settings::maximized),
      cancels_component = settings.get_or_create_component("cancels", aptitude_resolver_cost_settings::maximized),
      aardvarks_component = settings.get_or_create_component("aardvarks", aptitude_resolver_cost_settings::maximized),
      nonexistent_component = settings.get_or_create_component("llamas", aptitude_resolver_cost_settings::maximized);

    CPPUNIT_ASSERT_EQUAL(tier_operation::make_advance_user_level(0, 4),
                         settings.raise_cost(removals_component, 4));
    CPPUNIT_ASSERT_EQUAL(tier_operation::make_advance_user_level(0, 2) +
                         tier_operation::make_advance_user_level(2, 1),
                         settings.raise_cost(cancels_component, 1));
    CPPUNIT_ASSERT_EQUAL(tier_operation::make_advance_user_level(1, 5),
                         settings.raise_cost(aardvarks_component, 5));
    CPPUNIT_ASSERT_EQUAL(tier_operation(),
                         settings.add_to_cost(nonexistent_component, 100));

    CPPUNIT_ASSERT(settings.is_component_relevant(removals_component));
    CPPUNIT_ASSERT(settings.is_component_relevant(cancels_component));
    CPPUNIT_ASSERT(settings.is_component_relevant(aardvarks_component));
    CPPUNIT_ASSERT(!settings.is_component_relevant(nonexistent_component));
  }

  void testResolverCostSettingsMixed()
  {
    // Construct a settings object for:
    // max(removals, cancels), aardvarks, removals
    //
    // where "aardvarks" is flagged as additive (for extra fun).
    boost::shared_ptr<std::vector<cost_component_structure> > components =
      boost::make_shared<std::vector<cost_component_structure> >();


    std::vector<cost_component_structure::entry> c0;
    c0.push_back(cost_component_structure::entry("removals", 1));
    c0.push_back(cost_component_structure::entry("cancels", 2));

    std::vector<cost_component_structure::entry> c1;
    c1.push_back(cost_component_structure::entry("aardvarks", 1));

    std::vector<cost_component_structure::entry> c2;
    c2.push_back(cost_component_structure::entry("cancels", 1));

    components->push_back(cost_component_structure(cost_component_structure::combine_max, c0));
    components->push_back(cost_component_structure(cost_component_structure::combine_add, c1));
    components->push_back(cost_component_structure(cost_component_structure::combine_none, c2));


    aptitude_resolver_cost_settings settings(components);

    aptitude_resolver_cost_settings::component
      removals_component = settings.get_or_create_component("removals", aptitude_resolver_cost_settings::maximized),
      cancels_component = settings.get_or_create_component("cancels", aptitude_resolver_cost_settings::maximized),
      aardvarks_component = settings.get_or_create_component("aardvarks", aptitude_resolver_cost_settings::additive),
      nonexistent_component = settings.get_or_create_component("llamas", aptitude_resolver_cost_settings::maximized);

    CPPUNIT_ASSERT_EQUAL(tier_operation::make_advance_user_level(0, 4),
                         settings.raise_cost(removals_component, 4));
    CPPUNIT_ASSERT_EQUAL(tier_operation::make_advance_user_level(0, 2) +
                         tier_operation::make_advance_user_level(2, 1),
                         settings.raise_cost(cancels_component, 1));
    CPPUNIT_ASSERT_EQUAL(tier_operation::make_add_to_user_level(1, 5),
                         settings.add_to_cost(aardvarks_component, 5));
    CPPUNIT_ASSERT_EQUAL(tier_operation(),
                         settings.add_to_cost(nonexistent_component, 100));

    CPPUNIT_ASSERT(settings.is_component_relevant(removals_component));
    CPPUNIT_ASSERT(settings.is_component_relevant(cancels_component));
    CPPUNIT_ASSERT(settings.is_component_relevant(aardvarks_component));
    CPPUNIT_ASSERT(!settings.is_component_relevant(nonexistent_component));
  }

  void testResolverCostSettingsMismatch()
  {
    // Construct a settings object for:
    // max(removals, cancels), aardvarks, removals
    boost::shared_ptr<std::vector<cost_component_structure> > components =
      boost::make_shared<std::vector<cost_component_structure> >();

    std::vector<cost_component_structure::entry> c0;
    c0.push_back(cost_component_structure::entry("removals", 1));
    c0.push_back(cost_component_structure::entry("cancels", 2));

    std::vector<cost_component_structure::entry> c1;
    c1.push_back(cost_component_structure::entry("aardvarks", 1));

    std::vector<cost_component_structure::entry> c2;
    c2.push_back(cost_component_structure::entry("cancels", 1));

    components->push_back(cost_component_structure(cost_component_structure::combine_max, c0));
    components->push_back(cost_component_structure(cost_component_structure::combine_none, c1));
    components->push_back(cost_component_structure(cost_component_structure::combine_none, c2));


    aptitude_resolver_cost_settings settings(components);


    CPPUNIT_ASSERT_THROW(settings.get_or_create_component("removals", aptitude_resolver_cost_settings::additive),
                         CostTypeCheckFailure);
    CPPUNIT_ASSERT_THROW(settings.get_or_create_component("cancels", aptitude_resolver_cost_settings::additive),
                         CostTypeCheckFailure);

    aptitude_resolver_cost_settings::component
      removals_component = settings.get_or_create_component("removals", aptitude_resolver_cost_settings::maximized),
      cancels_component = settings.get_or_create_component("cancels", aptitude_resolver_cost_settings::maximized),
      aardvarks_component = settings.get_or_create_component("aardvarks", aptitude_resolver_cost_settings::maximized),
      nonexistent_component = settings.get_or_create_component("llamas", aptitude_resolver_cost_settings::maximized);

    CPPUNIT_ASSERT_THROW(settings.get_or_create_component("removals", aptitude_resolver_cost_settings::additive),
                         CostTypeCheckFailure);
    CPPUNIT_ASSERT_THROW(settings.get_or_create_component("aardvarks", aptitude_resolver_cost_settings::additive),
                         CostTypeCheckFailure);
    CPPUNIT_ASSERT_THROW(settings.get_or_create_component("cancels", aptitude_resolver_cost_settings::additive),
                         CostTypeCheckFailure);
    CPPUNIT_ASSERT_THROW(settings.get_or_create_component("llamas", aptitude_resolver_cost_settings::additive),
                         CostTypeCheckFailure);


    CPPUNIT_ASSERT_THROW(settings.add_to_cost(removals_component, 5), CostTypeCheckFailure);
    CPPUNIT_ASSERT_THROW(settings.add_to_cost(cancels_component, 2), CostTypeCheckFailure);
    CPPUNIT_ASSERT_THROW(settings.add_to_cost(aardvarks_component, 8), CostTypeCheckFailure);
  }

  void testResolverCostSettingsParse()
  {
    const std::string input =
      "removals+ 2*cancels + aardvarks, max(2 *removals, aardvarks, cancels), aardvarks, 4*removals, max(cancels),max(2*cancels)";

    boost::shared_ptr<std::vector<cost_component_structure> >
      parsed = parse_cost_settings(input);

    CPPUNIT_ASSERT_EQUAL((std::vector<cost_component_structure>::size_type)6, parsed->size());

    const cost_component_structure &level0 = (*parsed)[0];
    const cost_component_structure &level1 = (*parsed)[1];
    const cost_component_structure &level2 = (*parsed)[2];
    const cost_component_structure &level3 = (*parsed)[3];
    const cost_component_structure &level4 = (*parsed)[4];
    const cost_component_structure &level5 = (*parsed)[5];



    CPPUNIT_ASSERT_EQUAL(cost_component_structure::combine_add,
                         level0.get_combining_op());
    CPPUNIT_ASSERT_EQUAL((std::vector<cost_component_structure>::size_type)3,
                         level0.get_entries()->size());

    CPPUNIT_ASSERT_EQUAL(std::string("removals"), (*level0.get_entries())[0].get_name());
    CPPUNIT_ASSERT_EQUAL(1, (*level0.get_entries())[0].get_scaling_factor());

    CPPUNIT_ASSERT_EQUAL(std::string("cancels"), (*level0.get_entries())[1].get_name());
    CPPUNIT_ASSERT_EQUAL(2, (*level0.get_entries())[1].get_scaling_factor());

    CPPUNIT_ASSERT_EQUAL(std::string("aardvarks"), (*level0.get_entries())[2].get_name());
    CPPUNIT_ASSERT_EQUAL(1, (*level0.get_entries())[2].get_scaling_factor());



    CPPUNIT_ASSERT_EQUAL(cost_component_structure::combine_max,
                         level1.get_combining_op());
    CPPUNIT_ASSERT_EQUAL((std::vector<cost_component_structure>::size_type)3,
                         level1.get_entries()->size());

    CPPUNIT_ASSERT_EQUAL(std::string("removals"), (*level1.get_entries())[0].get_name());
    CPPUNIT_ASSERT_EQUAL(2, (*level1.get_entries())[0].get_scaling_factor());

    CPPUNIT_ASSERT_EQUAL(std::string("aardvarks"), (*level1.get_entries())[1].get_name());
    CPPUNIT_ASSERT_EQUAL(1, (*level1.get_entries())[1].get_scaling_factor());

    CPPUNIT_ASSERT_EQUAL(std::string("cancels"), (*level1.get_entries())[2].get_name());
    CPPUNIT_ASSERT_EQUAL(1, (*level1.get_entries())[2].get_scaling_factor());



    CPPUNIT_ASSERT_EQUAL(cost_component_structure::combine_none,
                         level2.get_combining_op());
    CPPUNIT_ASSERT_EQUAL((std::vector<cost_component_structure>::size_type)1, level2.get_entries()->size());

    CPPUNIT_ASSERT_EQUAL(std::string("aardvarks"), (*level2.get_entries())[0].get_name());
    CPPUNIT_ASSERT_EQUAL(1, (*level2.get_entries())[0].get_scaling_factor());




    CPPUNIT_ASSERT_EQUAL(cost_component_structure::combine_none,
                         level3.get_combining_op());
    CPPUNIT_ASSERT_EQUAL((std::vector<cost_component_structure>::size_type)1, level3.get_entries()->size());

    CPPUNIT_ASSERT_EQUAL(std::string("removals"), (*level3.get_entries())[0].get_name());
    CPPUNIT_ASSERT_EQUAL(4, (*level3.get_entries())[0].get_scaling_factor());



    CPPUNIT_ASSERT_EQUAL(cost_component_structure::combine_max,
                         level4.get_combining_op());
    CPPUNIT_ASSERT_EQUAL((std::vector<cost_component_structure>::size_type)1, level4.get_entries()->size());

    CPPUNIT_ASSERT_EQUAL(std::string("cancels"), (*level4.get_entries())[0].get_name());
    CPPUNIT_ASSERT_EQUAL(1, (*level4.get_entries())[0].get_scaling_factor());




    CPPUNIT_ASSERT_EQUAL(cost_component_structure::combine_max,
                         level5.get_combining_op());
    CPPUNIT_ASSERT_EQUAL((std::vector<cost_component_structure>::size_type)1, level5.get_entries()->size());

    CPPUNIT_ASSERT_EQUAL(std::string("cancels"), (*level5.get_entries())[0].get_name());
    CPPUNIT_ASSERT_EQUAL(2, (*level5.get_entries())[0].get_scaling_factor());
  }

  void testResolverCostSettingsParseFail()
  {
    const char * fail_inputs[] =
      {
        "max(",
        "max( , )",
        "max( asdf, )",
        "max)",
        "2*max(afd, e)",
        "max(asdf, 5)",
        "removals +",
        "(removals + cancels)",
        "removals + 5",
        "max(asdf, g + h)",
        "a, b, ",
        "a + , b",
        "a, + b"
      };
    int fail_inputs_length = sizeof(fail_inputs) / sizeof(fail_inputs[0]);

    for(int i = 0; i < fail_inputs_length; ++i)
      CPPUNIT_ASSERT_THROW(parse_cost_settings(fail_inputs[i]), ResolverCostParseException);
  }

  void testResolverCostSettingsSerialize()
  {
    // Construct a settings object for:
    // max(removals, 2*cancels), 5*aardvarks + badgers, groundhogs, max(llamas)
    //
    // where "aardvarks" is flagged as additive (for extra fun).
    boost::shared_ptr<std::vector<cost_component_structure> > components =
      boost::make_shared<std::vector<cost_component_structure> >();

    std::vector<cost_component_structure::entry> c0;
    c0.push_back(cost_component_structure::entry("removals", 1));
    c0.push_back(cost_component_structure::entry("cancels", 2));

    std::vector<cost_component_structure::entry> c1;
    c1.push_back(cost_component_structure::entry("aardvarks", 5));
    c1.push_back(cost_component_structure::entry("badgers", 1));

    std::vector<cost_component_structure::entry> c2;
    c2.push_back(cost_component_structure::entry("groundhogs", 1));

    std::vector<cost_component_structure::entry> c3;
    c3.push_back(cost_component_structure::entry("llamas", 1));

    components->push_back(cost_component_structure(cost_component_structure::combine_max, c0));
    components->push_back(cost_component_structure(cost_component_structure::combine_add, c1));
    components->push_back(cost_component_structure(cost_component_structure::combine_add, c2));
    components->push_back(cost_component_structure(cost_component_structure::combine_max, c3));


    aptitude_resolver_cost_settings settings(components);

    CPPUNIT_ASSERT_EQUAL(std::string("max(removals, 2*cancels), 5*aardvarks + badgers, groundhogs, max(llamas)"),
                         boost::lexical_cast<std::string>(settings));
  }
};

CPPUNIT_TEST_SUITE_REGISTRATION(ResolverCostsTest);