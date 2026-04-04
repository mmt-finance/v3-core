#[test_only]
module mmt_v3::ve_test;

use mmt_v3::admin;
use mmt_v3::app::{Self, Acl, VeCap, AdminCap};
use mmt_v3::collect;
use mmt_v3::constants;
use mmt_v3::full_math_u128;
use mmt_v3::pool;
use mmt_v3::position::Position;
use mmt_v3::test_helper::{Self as th, USDC, create_pool_, add_liquidity_};
use mmt_v3::tick_math;
use mmt_v3::trade;
use mmt_v3::utils;
use mmt_v3::ve;
use mmt_v3::version;
use sui::balance;
use sui::clock;
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario;

const SUI_DECIMALS: u64 = 1_000_000_000;
const USDC_DECIMALS: u64 = 1_000_000;
const DEFAULT_FEE_RATE: u64 = 100;
const DEFAULT_SQRT_PRICE: u128 = 597742825358017408; // sqrt price 1.05
const DEFAULT_LOWER_TICK: u128 = 583337266871351552; // lower price 1.0
const DEFAULT_UPPER_TICK: u128 = 611809286962066560; // upper price 1.1
const DEFAULT_LIQUIDITY_AMOUNT: u64 = 1000;

fun setup_test_environment<X, Y>(): (
    test_scenario::Scenario,
    version::Version,
    pool::Pool<X, Y>,
    Acl,
    VeCap,
    AdminCap,
    clock::Clock,
    address,
) {
    let tester = @0xAF;
    let mut scenario = test_scenario::begin(tester);
    let version = th::take_version(test_scenario::ctx(&mut scenario));

    create_pool_<X, Y>(
        DEFAULT_FEE_RATE,
        DEFAULT_SQRT_PRICE,
        true,
        &version,
        &mut scenario,
    );

    scenario.next_tx(tester);
    let pool = th::take_pool<X, Y>(&mut scenario);
    let mut acl = app::create_acl_for_testing(test_scenario::ctx(&mut scenario));
    let admin_cap = app::create_for_testing(test_scenario::ctx(&mut scenario));
    let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

    scenario.next_tx(tester);
    let ve_cap = app::issue_ve_cap(&admin_cap, &mut acl, test_scenario::ctx(&mut scenario));

    (scenario, version, pool, acl, ve_cap, admin_cap, clock, tester)
}

fun add_liquidity_to_pool<X, Y>(
    pool: &mut pool::Pool<X, Y>,
    clock: &clock::Clock,
    version: &version::Version,
    scenario: &mut test_scenario::Scenario,
    tester: address,
): (u64, u64, Position) {
    let lower_tick = tick_math::get_tick_at_sqrt_price(DEFAULT_LOWER_TICK);
    let upper_tick = tick_math::get_tick_at_sqrt_price(DEFAULT_UPPER_TICK);

    let (balance_x, balance_y, position) = add_liquidity_<X, Y>(
        pool,
        DEFAULT_LIQUIDITY_AMOUNT,
        DEFAULT_LIQUIDITY_AMOUNT,
        lower_tick,
        upper_tick,
        tester,
        clock,
        version,
        scenario,
    );

    (balance_x, balance_y, position)
}

fun cleanup_test_environment<X, Y>(
    scenario: test_scenario::Scenario,
    version: version::Version,
    pool: pool::Pool<X, Y>,
    acl: Acl,
    ve_cap: VeCap,
    admin_cap: AdminCap,
    clock: clock::Clock,
) {
    th::return_pool<X, Y>(pool);
    clock::destroy_for_testing(clock);
    version::destroy_version_for_testing(version);
    app::destroy_acl_for_testing(acl);
    app::destroy_ve_cap_for_testing(ve_cap);
    app::destroy_for_testing(admin_cap);
    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = 82)]
public fun ve_cap_already_issued() {
    let (
        mut scenario,
        version,
        mut pool,
        mut acl,
        ve_cap,
        admin_cap,
        clock,
        _,
    ) = setup_test_environment<SUI, USDC>();
    let ve_cap_2 = app::issue_ve_cap(&admin_cap, &mut acl, test_scenario::ctx(&mut scenario));
    app::destroy_ve_cap_for_testing(ve_cap_2);
    cleanup_test_environment(scenario, version, pool, acl, ve_cap, admin_cap, clock);
}

#[test]
public fun set_pool_ve_enabled_positive() {
    let (
        mut scenario,
        version,
        mut pool,
        acl,
        ve_cap,
        admin_cap,
        clock,
        tester,
    ) = setup_test_environment<SUI, USDC>();
    ve::set_pool_ve_enabled_state<SUI, USDC>(
        &mut pool,
        true,
        &version,
        &ve_cap,
    );
    assert!(pool::is_ve_enabled(&pool));
    let tx_result = test_scenario::next_tx(&mut scenario, tester);
    assert!(tx_result.num_user_events() == 1);

    assert!(pool::protocol_fee_share(&pool) == constants::protocol_fee_share_denominator());
    cleanup_test_environment(scenario, version, pool, acl, ve_cap, admin_cap, clock);
}

#[test, expected_failure(abort_code = 84)]
public fun set_pool_ve_enabled_negative() {
    let (
        mut scenario,
        version,
        mut pool,
        acl,
        ve_cap,
        admin_cap,
        clock,
        tester,
    ) = setup_test_environment<SUI, USDC>();
    ve::set_pool_ve_enabled_state<SUI, USDC>(
        &mut pool,
        true,
        &version,
        &ve_cap,
    );
    scenario.next_tx(tester);
    ve::set_pool_ve_enabled_state<SUI, USDC>(
        &mut pool,
        true,
        &version,
        &ve_cap,
    );
    cleanup_test_environment(scenario, version, pool, acl, ve_cap, admin_cap, clock);
}

#[test]
public fun protocol_fee_calculate_positive() {
    let (
        mut scenario,
        version,
        mut pool,
        acl,
        ve_cap,
        admin_cap,
        clock,
        tester,
    ) = setup_test_environment<SUI, USDC>();
    ve::set_pool_ve_enabled_state<SUI, USDC>(
        &mut pool,
        true,
        &version,
        &ve_cap,
    );
    scenario.next_tx(tester);
    let (_, _, position) = add_liquidity_to_pool(
        &mut pool,
        &clock,
        &version,
        &mut scenario,
        tester,
    );
    sui::transfer::public_transfer(position, tester);
    scenario.next_tx(tester);

    let mut is_x_to_y = true;
    let mut swap_amount = 10 * SUI_DECIMALS;

    let (balance_x, balance_y, rec) = trade::flash_swap<SUI, USDC>(
        &mut pool,
        is_x_to_y,
        true,
        swap_amount,
        4295048076,
        &clock,
        &version,
        test_scenario::ctx(&mut scenario),
    );
    balance_x.destroy_for_testing();
    balance_y.destroy_for_testing();

    let (pay_x, pay_y) = trade::swap_receipt_debts(&rec);
    trade::repay_flash_swap<SUI, USDC>(
        &mut pool,
        rec,
        balance::create_for_testing<SUI>(pay_x),
        balance::create_for_testing<USDC>(pay_y),
        &version,
        test_scenario::ctx(&mut scenario),
    );

    // after ve enabled, fee growth should be non-zero
    assert!(pool::fee_growth_global_x(&pool) == 0);
    // after ve enabled, protocol take all fees
    assert!(
        pool::protocol_fee_x(&pool) == swap_amount * DEFAULT_FEE_RATE / constants::fee_rate_denominator(),
    );

    scenario.next_tx(tester);

    // swap y to x
    is_x_to_y = false;
    swap_amount = 10 * USDC_DECIMALS;
    let (balance_x, balance_y, rec) = trade::flash_swap<SUI, USDC>(
        &mut pool,
        is_x_to_y,
        true,
        swap_amount,
        5833372668713515884,
        &clock,
        &version,
        test_scenario::ctx(&mut scenario),
    );
    balance_x.destroy_for_testing();
    balance_y.destroy_for_testing();

    let (pay_x, pay_y) = trade::swap_receipt_debts(&rec);
    trade::repay_flash_swap<SUI, USDC>(
        &mut pool,
        rec,
        balance::create_for_testing<SUI>(pay_x),
        balance::create_for_testing<USDC>(pay_y),
        &version,
        test_scenario::ctx(&mut scenario),
    );

    // after ve enabled, fee growth should be non-zero
    assert!(pool::fee_growth_global_y(&pool) == 0);
    // after ve enabled, protocol take all fees
    assert!(
        pool::protocol_fee_y(&pool) == swap_amount * DEFAULT_FEE_RATE / constants::fee_rate_denominator(),
    );

    cleanup_test_environment(scenario, version, pool, acl, ve_cap, admin_cap, clock);
}

#[test]
public fun collect_protocol_fee_positive() {
    let (
        mut scenario,
        version,
        mut pool,
        acl,
        ve_cap,
        admin_cap,
        clock,
        tester,
    ) = setup_test_environment<SUI, USDC>();
    ve::set_pool_ve_enabled_state<SUI, USDC>(
        &mut pool,
        true,
        &version,
        &ve_cap,
    );
    scenario.next_tx(tester);
    let (_, _, position) = add_liquidity_to_pool(
        &mut pool,
        &clock,
        &version,
        &mut scenario,
        tester,
    );
    sui::transfer::public_transfer(position, tester);
    scenario.next_tx(tester);

    let mut is_x_to_y = true;
    let mut swap_amount_x = 10 * SUI_DECIMALS;

    let (balance_x, balance_y, rec) = trade::flash_swap<SUI, USDC>(
        &mut pool,
        is_x_to_y,
        true,
        swap_amount_x,
        4295048076,
        &clock,
        &version,
        test_scenario::ctx(&mut scenario),
    );
    balance_x.destroy_for_testing();
    balance_y.destroy_for_testing();

    let (pay_x, pay_y) = trade::swap_receipt_debts(&rec);
    trade::repay_flash_swap<SUI, USDC>(
        &mut pool,
        rec,
        balance::create_for_testing<SUI>(pay_x),
        balance::create_for_testing<USDC>(pay_y),
        &version,
        test_scenario::ctx(&mut scenario),
    );

    scenario.next_tx(tester);
    // swap y to x
    is_x_to_y = false;
    let swap_amount_y = 10 * USDC_DECIMALS;
    let (balance_x, balance_y, rec) = trade::flash_swap<SUI, USDC>(
        &mut pool,
        is_x_to_y,
        true,
        swap_amount_y,
        5833372668713515884,
        &clock,
        &version,
        test_scenario::ctx(&mut scenario),
    );
    balance_x.destroy_for_testing();
    balance_y.destroy_for_testing();

    let (pay_x, pay_y) = trade::swap_receipt_debts(&rec);
    trade::repay_flash_swap<SUI, USDC>(
        &mut pool,
        rec,
        balance::create_for_testing<SUI>(pay_x),
        balance::create_for_testing<USDC>(pay_y),
        &version,
        test_scenario::ctx(&mut scenario),
    );

    scenario.next_tx(tester);
    // collect protocol fee
    let fee_x = swap_amount_x * DEFAULT_FEE_RATE / constants::fee_rate_denominator();
    let fee_y = swap_amount_y * DEFAULT_FEE_RATE / constants::fee_rate_denominator();
    let (balance_x, balance_y) = ve::collect_protocol_fee_with_cap(
        &mut pool,
        &ve_cap,
        fee_x,
        fee_y,
        &version,
        test_scenario::ctx(&mut scenario),
    );

    assert!(balance_x.value() == fee_x);
    assert!(balance_y.value() == fee_y);

    balance_x.destroy_for_testing();
    balance_y.destroy_for_testing();
    cleanup_test_environment(scenario, version, pool, acl, ve_cap, admin_cap, clock);
}

#[test, expected_failure(abort_code = 85)]
public fun collect_protocol_fee_negative_after_enable_ve() {
    let (
        mut scenario,
        version,
        mut pool,
        acl,
        ve_cap,
        admin_cap,
        clock,
        tester,
    ) = setup_test_environment<SUI, USDC>();
    ve::set_pool_ve_enabled_state<SUI, USDC>(
        &mut pool,
        true,
        &version,
        &ve_cap,
    );
    scenario.next_tx(tester);
    let (_, _, position) = add_liquidity_to_pool(
        &mut pool,
        &clock,
        &version,
        &mut scenario,
        tester,
    );
    sui::transfer::public_transfer(position, tester);
    scenario.next_tx(tester);

    let mut is_x_to_y = true;
    let mut swap_amount_x = 10 * SUI_DECIMALS;

    let (balance_x, balance_y, rec) = trade::flash_swap<SUI, USDC>(
        &mut pool,
        is_x_to_y,
        true,
        swap_amount_x,
        4295048076,
        &clock,
        &version,
        test_scenario::ctx(&mut scenario),
    );
    balance_x.destroy_for_testing();
    balance_y.destroy_for_testing();

    let (pay_x, pay_y) = trade::swap_receipt_debts(&rec);
    trade::repay_flash_swap<SUI, USDC>(
        &mut pool,
        rec,
        balance::create_for_testing<SUI>(pay_x),
        balance::create_for_testing<USDC>(pay_y),
        &version,
        test_scenario::ctx(&mut scenario),
    );

    scenario.next_tx(tester);
    // collect protocol fee
    let fee_x = swap_amount_x * DEFAULT_FEE_RATE / constants::fee_rate_denominator();
    let (balance_x, balance_y) = admin::collect_protocol_fee(
        &acl,
        &mut pool,
        fee_x,
        0,
        &version,
        test_scenario::ctx(&mut scenario),
    );

    balance_x.destroy_for_testing();
    balance_y.destroy_for_testing();
    cleanup_test_environment(scenario, version, pool, acl, ve_cap, admin_cap, clock);
}

#[test]
public fun initialize_pool_reward_with_cap_positive() {
    let (
        mut scenario,
        version,
        mut pool,
        acl,
        ve_cap,
        admin_cap,
        mut clock,
        _,
    ) = setup_test_environment<SUI, USDC>();
    clock::set_for_testing(&mut clock, 1756015200000);
    let start_time = utils::to_seconds(clock::timestamp_ms(&clock)) + 1;
    let additional_seconds = 1000;
    let reward_amount = 100 * SUI_DECIMALS;
    let initial_balance = balance::create_for_testing<SUI>(reward_amount);

    let (start_time_out, end_time_out) = ve::initialize_pool_reward_with_cap(
        &mut pool,
        &ve_cap,
        start_time,
        additional_seconds,
        initial_balance,
        &clock,
        &version,
        test_scenario::ctx(&mut scenario),
    );

    assert!(pool::reward_length(&pool) == 1);
    assert!(pool::reward_last_update_at(&pool, 0) == start_time);
    assert!(pool::reward_ended_at(&pool, 0) == start_time + additional_seconds);
    assert!(pool::total_reward(&pool, 0) == reward_amount);
    assert!(
        pool::reward_per_seconds(&pool, 0) ==  full_math_u128::mul_div_floor(
            reward_amount  as u128,
            mmt_v3::constants::q64() as u128,
            additional_seconds as u128
        ),
    );
    assert!(start_time_out == start_time);
    assert!(end_time_out == start_time + additional_seconds);
    cleanup_test_environment(scenario, version, pool, acl, ve_cap, admin_cap, clock);
}

#[test]
public fun initialize_pool_reward_admin_positive() {
    let (
        mut scenario,
        version,
        mut pool,
        acl,
        ve_cap,
        admin_cap,
        mut clock,
        _,
    ) = setup_test_environment<SUI, USDC>();
    clock::set_for_testing(&mut clock, 1756015200000);
    let start_time = utils::to_seconds(clock::timestamp_ms(&clock)) + 1;
    let additional_seconds = 1000;
    let reward_amount = 100 * SUI_DECIMALS;
    let initial_balance = balance::create_for_testing<SUI>(reward_amount);

    admin::initialize_pool_reward(
        &acl,
        &mut pool,
        start_time,
        additional_seconds,
        initial_balance,
        &clock,
        &version,
        test_scenario::ctx(&mut scenario),
    );

    assert!(pool::reward_length(&pool) == 1);
    assert!(pool::reward_last_update_at(&pool, 0) == start_time);
    assert!(pool::reward_ended_at(&pool, 0) == start_time + additional_seconds);
    assert!(pool::total_reward(&pool, 0) == reward_amount);
    assert!(
        pool::reward_per_seconds(&pool, 0) ==  full_math_u128::mul_div_floor(
            reward_amount  as u128,
            mmt_v3::constants::q64() as u128,
            additional_seconds as u128
        ),
    );
    cleanup_test_environment(scenario, version, pool, acl, ve_cap, admin_cap, clock);
}

#[test]
public fun update_pool_reward_emission_with_cap_positive() {
    let (
        mut scenario,
        version,
        mut pool,
        acl,
        ve_cap,
        admin_cap,
        mut clock,
        tester,
    ) = setup_test_environment<SUI, USDC>();
    clock::set_for_testing(&mut clock, 1756015200000);
    let start_time = utils::to_seconds(clock::timestamp_ms(&clock)) + 1;
    let additional_seconds = 1000;
    let reward_amount = 100 * SUI_DECIMALS;
    let initial_balance = balance::create_for_testing<SUI>(reward_amount);

    let (_, end_time_out) = ve::initialize_pool_reward_with_cap(
        &mut pool,
        &ve_cap,
        start_time,
        additional_seconds,
        initial_balance,
        &clock,
        &version,
        test_scenario::ctx(&mut scenario),
    );

    scenario.next_tx(tester);
    let add_balance = balance::create_for_testing<SUI>(reward_amount);
    let (before_end_time, new_end_time) = ve::update_pool_reward_emission_with_cap(
        &mut pool,
        &ve_cap,
        add_balance,
        additional_seconds,
        &clock,
        &version,
        test_scenario::ctx(&mut scenario),
    );

    assert!(before_end_time == end_time_out);
    assert!(new_end_time == start_time + additional_seconds * 2);
    cleanup_test_environment(scenario, version, pool, acl, ve_cap, admin_cap, clock);
}

#[test]
public fun update_pool_reward_emission_admin_positive() {
    let (
        mut scenario,
        version,
        mut pool,
        acl,
        ve_cap,
        admin_cap,
        mut clock,
        tester,
    ) = setup_test_environment<SUI, USDC>();

    clock::set_for_testing(&mut clock, 1756015200000);
    let start_time = utils::to_seconds(clock::timestamp_ms(&clock)) + 1;
    let additional_seconds = 1000;
    let reward_amount = 100 * SUI_DECIMALS;
    let initial_balance = balance::create_for_testing<SUI>(reward_amount);

    admin::initialize_pool_reward(
        &acl,
        &mut pool,
        start_time,
        additional_seconds,
        initial_balance,
        &clock,
        &version,
        test_scenario::ctx(&mut scenario),
    );

    scenario.next_tx(tester);
    clock::set_for_testing(&mut clock, 1756216177000);
    let last_update_time = utils::to_seconds(clock::timestamp_ms(&clock));
    let add_balance = balance::create_for_testing<SUI>(reward_amount);
    let update_additional_seconds = 2592000; // 30 days
    admin::update_pool_reward_emission(
        &acl,
        &mut pool,
        add_balance,
        update_additional_seconds,
        &clock,
        &version,
        test_scenario::ctx(&mut scenario),
    );

    let new_end_time = start_time + additional_seconds + update_additional_seconds;
    assert!(pool::reward_length(&pool) == 1);
    assert!(pool::reward_last_update_at(&pool, 0) == last_update_time);
    assert!(pool::reward_ended_at(&pool, 0) == new_end_time);
    assert!(pool::total_reward(&pool, 0) == reward_amount * 2);
    assert!(
        pool::reward_per_seconds(&pool, 0) ==  full_math_u128::mul_div_floor(
            (reward_amount * 2)  as u128,
            mmt_v3::constants::q64() as u128,
            (new_end_time - last_update_time) as u128
        ),
    );
    cleanup_test_environment(scenario, version, pool, acl, ve_cap, admin_cap, clock);
}

const ONE_DAY_SECONDS: u64 = 86400;
const HALF_DAY_SECONDS: u64 = 43200;

#[test]
public fun reward_collect_after_ve_swap_and_elapse() {
    let (
        mut scenario,
        version,
        mut pool,
        acl,
        ve_cap,
        admin_cap,
        mut clock,
        tester,
    ) = setup_test_environment<SUI, USDC>();

    ve::set_pool_ve_enabled_state<SUI, USDC>(
        &mut pool,
        true,
        &version,
        &ve_cap,
    );
    scenario.next_tx(tester);

    clock::set_for_testing(&mut clock, 1756015200000);
    let start_time = utils::to_seconds(clock::timestamp_ms(&clock)) + 1;
    let additional_seconds = ONE_DAY_SECONDS;
    let reward_amount = 100 * SUI_DECIMALS;
    let initial_balance = balance::create_for_testing<SUI>(reward_amount);

    let (_, _) = ve::initialize_pool_reward_with_cap(
        &mut pool,
        &ve_cap,
        start_time,
        additional_seconds,
        initial_balance,
        &clock,
        &version,
        test_scenario::ctx(&mut scenario),
    );

    scenario.next_tx(tester);
    clock::increment_for_testing(&mut clock, 1000 * 1000);

    let (_, _, position) = add_liquidity_to_pool(
        &mut pool,
        &clock,
        &version,
        &mut scenario,
        tester,
    );
    sui::transfer::public_transfer(position, tester);
    scenario.next_tx(tester);

    let is_x_to_y = true;
    let swap_amount = 10 * SUI_DECIMALS;
    let (balance_x, balance_y, rec) = trade::flash_swap<SUI, USDC>(
        &mut pool,
        is_x_to_y,
        true,
        swap_amount,
        4295048076,
        &clock,
        &version,
        test_scenario::ctx(&mut scenario),
    );
    balance_x.destroy_for_testing();
    balance_y.destroy_for_testing();

    let (pay_x, pay_y) = trade::swap_receipt_debts(&rec);
    trade::repay_flash_swap<SUI, USDC>(
        &mut pool,
        rec,
        balance::create_for_testing<SUI>(pay_x),
        balance::create_for_testing<USDC>(pay_y),
        &version,
        test_scenario::ctx(&mut scenario),
    );

    scenario.next_tx(tester);
    clock::increment_for_testing(&mut clock, HALF_DAY_SECONDS * 1000);
    scenario.next_tx(tester);

    let mut position = th::take_position(&mut scenario, tester);
    let reward_coin = collect::reward<SUI, USDC, SUI>(
        &mut pool,
        &mut position,
        &clock,
        &version,
        test_scenario::ctx(&mut scenario),
    );
    std::debug::print(&coin::value(&reward_coin));
    assert!(coin::value(&reward_coin) > 0);
    coin::burn_for_testing(reward_coin);

    th::return_position(position, tester);
    cleanup_test_environment(scenario, version, pool, acl, ve_cap, admin_cap, clock);
}




// #[test]
// public fun reward_collect_after_ve_swap_and_elapse_2() {
//     let (
//         mut scenario,
//         version,
//         mut pool,
//         acl,
//         ve_cap,
//         admin_cap,
//         mut clock,
//         tester,
//     ) = setup_test_environment<SUI, USDC>();

//     ve::set_pool_ve_enabled_state<SUI, USDC>(
//         &mut pool,
//         true,
//         &version,
//         &ve_cap,
//     );
//     scenario.next_tx(tester);

//     clock::set_for_testing(&mut clock, 1756015200000);
//     let start_time = utils::to_seconds(clock::timestamp_ms(&clock)) + 1;
//     let additional_seconds = ONE_DAY_SECONDS;
//     let reward_amount = 100 * SUI_DECIMALS;
//     let initial_balance = balance::create_for_testing<SUI>(reward_amount);

//     let (_, _) = ve::initialize_pool_reward_with_cap(
//         &mut pool,
//         &ve_cap,
//         start_time,
//         additional_seconds,
//         initial_balance,
//         &clock,
//         &version,
//         test_scenario::ctx(&mut scenario),
//     );

//     scenario.next_tx(tester);
//     clock::increment_for_testing(&mut clock, 1000 * 1000);

//     let (_, _, position) = add_liquidity_to_pool(
//         &mut pool,
//         &clock,
//         &version,
//         &mut scenario,
//         tester,
//     );
//     sui::transfer::public_transfer(position, tester);
//     scenario.next_tx(tester);

//     let is_x_to_y = true;
//     let swap_amount = 10 * SUI_DECIMALS;
//     let (balance_x, balance_y, rec) = trade::flash_swap<SUI, USDC>(
//         &mut pool,
//         is_x_to_y,
//         true,
//         swap_amount,
//         4295048076,
//         &clock,
//         &version,
//         test_scenario::ctx(&mut scenario),
//     );
//     balance_x.destroy_for_testing();
//     balance_y.destroy_for_testing();

//     let (pay_x, pay_y) = trade::swap_receipt_debts(&rec);
//     trade::repay_flash_swap<SUI, USDC>(
//         &mut pool,
//         rec,
//         balance::create_for_testing<SUI>(pay_x),
//         balance::create_for_testing<USDC>(pay_y),
//         &version,
//         test_scenario::ctx(&mut scenario),
//     );

//     scenario.next_tx(tester);
//     clock::increment_for_testing(&mut clock, HALF_DAY_SECONDS * 1000);
//     scenario.next_tx(tester);

//     let mut position = th::take_position(&mut scenario, tester);
//     let reward_coin = collect::reward<SUI, USDC, SUI>(
//         &mut pool,
//         &mut position,
//         &clock,
//         &version,
//         test_scenario::ctx(&mut scenario),
//     );
//     std::debug::print(&coin::value(&reward_coin));
//     assert!(coin::value(&reward_coin) > 0);
//     coin::burn_for_testing(reward_coin);

//     th::return_position(position, tester);
//     cleanup_test_environment(scenario, version, pool, acl, ve_cap, admin_cap, clock);
// }

