module mmt_v3::admin;

use mmt_v3::app::{Self, Acl, AdminCap};
use mmt_v3::constants;
use mmt_v3::error;
use mmt_v3::full_math_u64;
use mmt_v3::pool::{Self, Pool};
use mmt_v3::utils;
use mmt_v3::version::{Self, Version};
use std::type_name;
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::event;
use sui::math;

// events
public struct CollectProtocolFeeEvent has copy, drop, store {
    sender: address,
    pool_id: ID,
    amount_x: u64,
    amount_y: u64,
}

public struct SetProtocolSwapFeeRateEvent has copy, drop, store {
    sender: address,
    pool_id: ID,
    protocol_fee_share_old: u64,
    protocol_fee_share_new: u64,
}

public struct SetProtocolFlashLoanFeeRateEvent has copy, drop, store {
    sender: address,
    pool_id: ID,
    protocol_fee_share_old: u64,
    protocol_fee_share_new: u64,
}

public struct SetSwapFeeRateEvent has copy, drop, store {
    sender: address,
    pool_id: ID,
    swap_fee_rate_old: u64,
    swap_fee_rate_new: u64,
}

public struct SetFlashLoanFeeRateEvent has copy, drop, store {
    sender: address,
    pool_id: ID,
    flash_loan_fee_rate_old: u64,
    flash_loan_fee_rate_new: u64,
}

public fun initialize_pool_reward<X, Y, R>(
    acl: &Acl,
    pool: &mut Pool<X, Y>,
    start_time: u64,
    additional_seconds: u64,
    initial_balance: Balance<R>,
    clock: &Clock,
    version: &Version,
    ctx: &TxContext,
) {
    version::assert_supported_version(version);
    pool::assert_not_pause(pool);

    assert!(app::get_rewarder_admin(acl) == tx_context::sender(ctx), error::not_authorised());

    initialize_pool_reward_<X, Y, R>(
        pool,
        start_time,
        additional_seconds,
        initial_balance,
        clock,
        ctx,
    );
}

public(package) fun initialize_pool_reward_<X, Y, R>(
    pool: &mut Pool<X, Y>,
    start_time: u64,
    additional_seconds: u64,
    initial_balance: Balance<R>,
    clock: &Clock,
    ctx: &TxContext,
): (u64, u64) {
    assert!(start_time > utils::to_seconds(clock::timestamp_ms(clock)), error::invalid_timestamp());

    let reward_coin_type = type_name::get<R>();
    let pool_reward_info = pool::default_reward_info(reward_coin_type, start_time);
    pool::add_reward_info<X, Y, R>(pool, pool_reward_info, ctx);

    pool::update_pool_reward_emission<X, Y, R>(pool, initial_balance, additional_seconds, ctx)
}

public fun collect_protocol_fee<X, Y>(
    acl: &Acl,
    pool: &mut Pool<X, Y>,
    amount_x: u64,
    amount_y: u64,
    version: &Version,
    ctx: &TxContext,
): (Balance<X>, Balance<Y>) {
    version::assert_supported_version(version);
    pool::assert_not_pause(pool);
    assert!(!pool::is_ve_enabled(pool), error::forbidden_after_ve());

    assert!(app::get_pool_admin(acl) == tx_context::sender(ctx), error::not_authorised());

    collect_protocol_fees_(pool, amount_x, amount_y, ctx)
}

public(package) fun collect_protocol_fees_<X, Y>(
    pool: &mut Pool<X, Y>,
    amount_x: u64,
    amount_y: u64,
    ctx: &TxContext,
): (Balance<X>, Balance<Y>) {
    let min_amount_x = math::min(amount_x, pool::protocol_fee_x(pool));
    let min_amount_y = math::min(amount_y, pool::protocol_fee_y(pool));
    let protocol_fee_x = pool::protocol_fee_x(pool);
    let protocol_fee_y = pool::protocol_fee_y(pool);

    pool::set_protocol_fee_x(pool, protocol_fee_x - min_amount_x);
    pool::set_protocol_fee_y(pool, protocol_fee_y - min_amount_y);

    event::emit(CollectProtocolFeeEvent {
        sender: tx_context::sender(ctx),
        pool_id: object::id(pool),
        amount_x: min_amount_x,
        amount_y: min_amount_y,
    });
    pool::take_from_reserves<X, Y>(pool, min_amount_x, min_amount_y)
}

public fun add_seconds_to_reward_emission<X, Y, R>(
    acl: &Acl,
    pool: &mut Pool<X, Y>,
    additional_seconds: u64,
    clock: &Clock,
    version: &Version,
    ctx: &TxContext,
) {
    version::assert_supported_version(version);
    pool::assert_not_pause(pool);

    assert!(app::get_rewarder_admin(acl) == tx_context::sender(ctx), error::not_authorised());

    pool::update_reward_infos<X, Y>(
        pool,
        utils::to_seconds(clock::timestamp_ms(clock)),
    );
    pool::update_pool_reward_emission<X, Y, R>(
        pool,
        balance::zero<R>(),
        additional_seconds,
        ctx,
    );
}

public fun update_pool_reward_emission<X, Y, R>(
    acl: &Acl,
    pool: &mut Pool<X, Y>,
    additional_balance: Balance<R>,
    additional_seconds: u64,
    clock: &Clock,
    version: &Version,
    ctx: &TxContext,
) {
    version::assert_supported_version(version);
    pool::assert_not_pause(pool);

    assert!(app::get_rewarder_admin(acl) == tx_context::sender(ctx), error::not_authorised());

    update_pool_reward_emission_(pool, additional_balance, additional_seconds, clock, ctx);
}

public(package) fun update_pool_reward_emission_<X, Y, R>(
    pool: &mut Pool<X, Y>,
    additional_balance: Balance<R>,
    additional_seconds: u64,
    clock: &Clock,
    ctx: &TxContext,
): (u64, u64) {
    pool::update_reward_infos<X, Y>(
        pool,
        utils::to_seconds(clock::timestamp_ms(clock)),
    );
    pool::update_pool_reward_emission<X, Y, R>(pool, additional_balance, additional_seconds, ctx)
}

// fee operations
public fun set_protocol_flash_loan_fee_share<X, Y>(
    acl: &Acl,
    pool: &mut Pool<X, Y>,
    new_protocol_flash_loan_fee_share: u64,
    version: &Version,
    ctx: &TxContext,
) {
    version::assert_supported_version(version);
    pool::assert_not_pause(pool);

    assert!(app::get_pool_admin(acl) == tx_context::sender(ctx), error::not_authorised());

    assert!(
        new_protocol_flash_loan_fee_share >= 0 && // share >= zero
            new_protocol_flash_loan_fee_share <= get_max_protocol_fee_share(), // max 75% share with scalling factor 10^6
        error::invalid_protocol_fee(),
    );

    let event = SetProtocolFlashLoanFeeRateEvent {
        sender: tx_context::sender(ctx),
        pool_id: object::id<Pool<X, Y>>(pool),
        protocol_fee_share_old: pool::protocol_flash_loan_fee_share(pool),
        protocol_fee_share_new: new_protocol_flash_loan_fee_share,
    };

    pool::set_protocol_flash_loan_fee_share(pool, new_protocol_flash_loan_fee_share);

    event::emit<SetProtocolFlashLoanFeeRateEvent>(event);
}

public fun set_protocol_swap_fee_share<X, Y>(
    acl: &Acl,
    pool: &mut Pool<X, Y>,
    new_protocol_fee_share: u64,
    version: &Version,
    ctx: &TxContext,
) {
    version::assert_supported_version(version);
    pool::assert_not_pause(pool);

    assert!(app::get_pool_admin(acl) == tx_context::sender(ctx), error::not_authorised());

    assert!(
        new_protocol_fee_share >= 0 && // share >= zero
            new_protocol_fee_share <= get_max_protocol_fee_share(), // max 75% share with scalling factor 10^6
        error::invalid_protocol_fee(),
    );

    let event = SetProtocolSwapFeeRateEvent {
        sender: tx_context::sender(ctx),
        pool_id: object::id<Pool<X, Y>>(pool),
        protocol_fee_share_old: pool::protocol_fee_share(pool),
        protocol_fee_share_new: new_protocol_fee_share,
    };

    pool::set_protocol_fee_share(pool, new_protocol_fee_share);

    event::emit<SetProtocolSwapFeeRateEvent>(event);
}

public fun set_swap_fee_rate<X, Y>(
    acl: &Acl,
    pool: &mut Pool<X, Y>,
    new_swap_fee_rate: u64,
    version: &Version,
    ctx: &TxContext,
) {
    version::assert_supported_version(version);
    pool::assert_not_pause(pool);

    assert!(app::get_pool_admin(acl) == tx_context::sender(ctx), error::not_authorised());

    assert!(
        new_swap_fee_rate > 0 &&
                new_swap_fee_rate < 1000000,
        error::invalid_fee_rate(),
    );

    let event = SetSwapFeeRateEvent {
        sender: tx_context::sender(ctx),
        pool_id: object::id<Pool<X, Y>>(pool),
        swap_fee_rate_old: pool::swap_fee_rate(pool),
        swap_fee_rate_new: new_swap_fee_rate,
    };

    pool::set_swap_fee_rate(pool, new_swap_fee_rate);

    event::emit<SetSwapFeeRateEvent>(event);
}

public fun set_flash_loan_fee_rate<X, Y>(
    acl: &Acl,
    pool: &mut Pool<X, Y>,
    new_flash_loan_fee_rate: u64,
    version: &Version,
    ctx: &TxContext,
) {
    version::assert_supported_version(version);
    pool::assert_not_pause(pool);

    assert!(app::get_pool_admin(acl) == tx_context::sender(ctx), error::not_authorised());

    assert!(
        new_flash_loan_fee_rate > 0 &&
                new_flash_loan_fee_rate < 1000000,
        error::invalid_fee_rate(),
    );

    let event = SetFlashLoanFeeRateEvent {
        sender: tx_context::sender(ctx),
        pool_id: object::id<Pool<X, Y>>(pool),
        flash_loan_fee_rate_old: pool.flash_loan_fee_rate(),
        flash_loan_fee_rate_new: new_flash_loan_fee_rate,
    };

    pool::set_flash_loan_fee_rate(pool, new_flash_loan_fee_rate);

    event::emit<SetFlashLoanFeeRateEvent>(event);
}

public fun increase_observation_cardinality_next<X, Y>(
    acl: &Acl,
    pool: &mut Pool<X, Y>,
    new_cardinality: u64,
    ctx: &TxContext,
) {
    assert!(app::get_pool_admin(acl) == tx_context::sender(ctx), error::not_authorised());
    pool::assert_not_pause(pool);

    pool::increase_observation_cardinality_next(pool, new_cardinality, ctx);
}

public fun toggle_trading<X, Y>(_: &AdminCap, pool: &mut Pool<X, Y>, val: bool, _ctx: &TxContext) {
    pool::toggle_trading(_, pool, val);
}

public fun get_max_protocol_fee_share(): u64 {
    full_math_u64::mul_div_floor(
        constants::protocol_fee_share_denominator(),
        constants::max_protocol_fee_percent(),
        100,
    )
}
