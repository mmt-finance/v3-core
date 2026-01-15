module mmt_v3::pool;

use mmt_v3::app::{Self, AdminCap, Acl};
use mmt_v3::constants;
use mmt_v3::error;
use mmt_v3::full_math_u128;
use mmt_v3::i128::{Self, I128};
use mmt_v3::i32::{Self, I32};
use mmt_v3::i64;
use mmt_v3::liquidity_math;
use mmt_v3::oracle::{Self, Observation};
use mmt_v3::position::{Self, Position};
use mmt_v3::tick::{Self, TickInfo};
use mmt_v3::tick_bitmap;
use mmt_v3::tick_math;
use mmt_v3::utils;
use mmt_v3::version::{Self, Version};
use std::type_name::{Self, TypeName};
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::dynamic_field::{Self, Self as df};
use sui::event;
use sui::math;
use sui::table::{Self, Table};

// ----- Use Statements -----

// ----- public structs -----

public struct Pool<phantom X, phantom Y> has key {
    id: UID,
    type_x: TypeName,
    type_y: TypeName,
    // current state of pool
    sqrt_price: u128,
    liquidity: u128,
    tick_index: I32,
    // global configs
    tick_spacing: u32,
    max_liquidity_per_tick: u128,
    fee_growth_global_x: u128,
    fee_growth_global_y: u128,
    // pool reserves
    reserve_x: Balance<X>,
    reserve_y: Balance<Y>,
    // fees
    swap_fee_rate: u64,
    flash_loan_fee_rate: u64,
    protocol_fee_share: u64,
    protocol_flash_loan_fee_share: u64,
    protocol_fee_x: u64, // collected fee x
    protocol_fee_y: u64, // collected fee y
    // tick data
    ticks: Table<I32, TickInfo>,
    tick_bitmap: Table<I32, u256>,
    // rewards
    reward_infos: vector<PoolRewardInfo>,
    // oracle observations data
    observation_index: u64,
    observation_cardinality: u64,
    observation_cardinality_next: u64,
    observations: vector<Observation>,
}

public struct PoolRewardInfo has copy, drop, store {
    reward_coin_type: TypeName,
    last_update_time: u64,
    ended_at_seconds: u64,
    total_reward: u64,
    total_reward_allocated: u64,
    reward_per_seconds: u128,
    reward_growth_global: u128,
}

public struct PoolRewardCustodianDfKey<phantom X> has copy, drop, store {
    dummy_field: bool,
}

public struct MinTickRangeDfKey has copy, drop, store {}

public struct VeEnabledDfKey has copy, drop, store {}

// events
public struct ObservationCardinalityUpdatedEvent has copy, drop, store {
    sender: address,
    pool_id: ID,
    observation_cardinality_next_old: u64,
    observation_cardinality_next_new: u64,
}

public struct UpdatePoolRewardEmissionEvent has copy, drop, store {
    sender: address,
    pool_id: ID,
    reward_coin_type: TypeName,
    total_reward: u64,
    ended_at_seconds: u64,
    reward_per_seconds: u128,
}

public struct PoolPausedEvent has copy, drop, store {
    sender: address,
    pool_id: ID,
    type_x: TypeName,
    type_y: TypeName,
    paused: bool,
}

public struct SetMinTickRangeFactorEvent has copy, drop, store {
    sender: address,
    pool_id: ID,
    min_tick_range_factor: u32,
}

public struct ToggleTradingEvent has copy, drop, store {
    pool_id: ID,
    toggle_trading: bool,
}

public struct VeStateChangedEvent has copy, drop, store {
    pool_id: ID,
    ve_enabled: bool,
}

// ----- Public Functions -----

public fun initialize<X, Y>(pool: &mut Pool<X, Y>, sqrt_price: u128, clock: &Clock) {
    assert!(pool.sqrt_price == 0, error::invalid_initialization());

    let tick_index = tick_math::get_tick_at_sqrt_price(sqrt_price);
    pool.tick_index = tick_index;
    pool.sqrt_price = sqrt_price;
    let (observation_cardinality, observation_cardinality_next) = oracle::initialize(
        &mut pool.observations,
        utils::to_seconds(clock::timestamp_ms(clock)),
    );
    pool.observation_cardinality = observation_cardinality;
    pool.observation_cardinality_next = observation_cardinality_next;

    let min_tick_range_key = MinTickRangeDfKey {};
    dynamic_field::add<MinTickRangeDfKey, u32>(
        &mut pool.id,
        min_tick_range_key,
        mmt_v3::constants::default_min_tick_range_factor(),
    );
}

public fun verify_pool<X, Y>(pool: &Pool<X, Y>, id: ID) {
    assert!(object::id(pool) == id, error::invalid_pool_match());
}

#[allow(lint(share_owned))]
public fun transfer<X, Y>(self: Pool<X, Y>) {
    transfer::share_object<Pool<X, Y>>(self);
}

public fun borrow_observations<X, Y>(pool: &Pool<X, Y>): &vector<Observation> { &pool.observations }

public fun borrow_tick_bitmap<X, Y>(pool: &Pool<X, Y>): &Table<I32, u256> { &pool.tick_bitmap }

public fun borrow_ticks<X, Y>(pool: &Pool<X, Y>): &Table<I32, TickInfo> { &pool.ticks }

public fun get_reserves<X, Y>(pool: &Pool<X, Y>): (u64, u64) {
    (balance::value(&pool.reserve_x), balance::value(&pool.reserve_y))
}

// pool getters
public fun type_x<X, Y>(pool: &Pool<X, Y>): TypeName { pool.type_x }

public fun type_y<X, Y>(pool: &Pool<X, Y>): TypeName { pool.type_y }

public fun liquidity<X, Y>(pool: &Pool<X, Y>): u128 { pool.liquidity }

public fun sqrt_price<X, Y>(self: &Pool<X, Y>): u128 { self.sqrt_price }

public fun tick_index_current<X, Y>(pool: &Pool<X, Y>): I32 { pool.tick_index }

public fun tick_spacing<X, Y>(pool: &Pool<X, Y>): u32 { pool.tick_spacing }

public fun max_liquidity_per_tick<X, Y>(pool: &Pool<X, Y>): u128 { pool.max_liquidity_per_tick }

public fun observation_cardinality<X, Y>(pool: &Pool<X, Y>): u64 { pool.observation_cardinality }

public fun observation_cardinality_next<X, Y>(pool: &Pool<X, Y>): u64 {
    pool.observation_cardinality_next
}

public fun observation_index<X, Y>(pool: &Pool<X, Y>): u64 { pool.observation_index }

public fun pool_id<X, Y>(pool: &Pool<X, Y>): ID { object::id(pool) }

public fun swap_fee_rate<X, Y>(self: &Pool<X, Y>): u64 { self.swap_fee_rate }

public fun flash_loan_fee_rate<X, Y>(self: &Pool<X, Y>): u64 { self.flash_loan_fee_rate }

public fun protocol_fee_share<X, Y>(pool: &Pool<X, Y>): u64 { pool.protocol_fee_share }

public fun protocol_flash_loan_fee_share<X, Y>(pool: &Pool<X, Y>): u64 {
    pool.protocol_flash_loan_fee_share
}

public fun protocol_fee_x<X, Y>(pool: &Pool<X, Y>): u64 { pool.protocol_fee_x }

public fun protocol_fee_y<X, Y>(pool: &Pool<X, Y>): u64 { pool.protocol_fee_y }

public fun reserves<X, Y>(pool: &Pool<X, Y>): (u64, u64) {
    (balance::value(&pool.reserve_x), balance::value(&pool.reserve_y))
}

public fun reward_coin_type<X, Y>(pool: &Pool<X, Y>, index: u64): TypeName {
    reward_info_at<X, Y>(pool, index).reward_coin_type
}

public fun fee_growth_global_x<X, Y>(pool: &Pool<X, Y>): u128 { pool.fee_growth_global_x }

public fun fee_growth_global_y<X, Y>(pool: &Pool<X, Y>): u128 { pool.fee_growth_global_y }

public fun min_tick_range_factor<X, Y>(pool: &Pool<X, Y>): u32 {
    let key = MinTickRangeDfKey {};
    if (dynamic_field::exists_<MinTickRangeDfKey>(&pool.id, key)) {
        let val = dynamic_field::borrow<MinTickRangeDfKey, u32>(&pool.id, key);
        *val
    } else {
        mmt_v3::constants::default_min_tick_range_factor()
    }
}

public fun is_ve_enabled<X, Y>(pool: &Pool<X, Y>): bool {
    let key = VeEnabledDfKey {};
    if (dynamic_field::exists_<VeEnabledDfKey>(&pool.id, key)) {
        let val = dynamic_field::borrow<VeEnabledDfKey, bool>(&pool.id, key);
        *val
    } else {
        false
    }
}

// oracle public functions
public fun observe<X, Y>(
    pool: &Pool<X, Y>,
    seconds_ago: vector<u64>,
    clock: &Clock,
): (vector<i64::I64>, vector<u256>) {
    oracle::observe(
        &pool.observations,
        utils::to_seconds(clock::timestamp_ms(clock)),
        seconds_ago,
        pool.tick_index,
        pool.observation_index,
        pool.liquidity,
        pool.observation_cardinality,
    )
}

// rewards getters
public fun total_reward<X, Y>(pool: &Pool<X, Y>, reward_index: u64): u64 {
    reward_info_at<X, Y>(pool, reward_index).total_reward
}

public fun total_reward_allocated<X, Y>(pool: &Pool<X, Y>, reward_index: u64): u64 {
    reward_info_at<X, Y>(pool, reward_index).total_reward_allocated
}

public fun reward_ended_at<X, Y>(pool: &Pool<X, Y>, reward_index: u64): u64 {
    reward_info_at<X, Y>(pool, reward_index).ended_at_seconds
}

public fun reward_growth_global<X, Y>(pool: &Pool<X, Y>, reward_index: u64): u128 {
    reward_info_at<X, Y>(pool, reward_index).reward_growth_global
}

public fun reward_last_update_at<X, Y>(pool: &Pool<X, Y>, reward_index: u64): u64 {
    reward_info_at<X, Y>(pool, reward_index).last_update_time
}

public fun reward_per_seconds<X, Y>(pool: &Pool<X, Y>, reward_index: u64): u128 {
    reward_info_at<X, Y>(pool, reward_index).reward_per_seconds
}

public fun reward_length<X, Y>(pool: &Pool<X, Y>): u64 { vector::length(&pool.reward_infos) }

public fun reward_info_at<X, Y>(pool: &Pool<X, Y>, index: u64): &PoolRewardInfo {
    assert!(index < reward_length<X, Y>(pool), error::index_out_of_bounds());
    vector::borrow(&pool.reward_infos, index)
}

// returns friendly ticks by adjusting tick spacing of the pool.
public fun get_friendly_ticks<X, Y>(
    pool: &Pool<X, Y>,
    lower_sqrt_price: u128,
    upper_sqrt_price: u128,
): (I32, I32) {
    let lower_tick = tick_math::get_tick_at_sqrt_price(lower_sqrt_price);
    let upper_tick = tick_math::get_tick_at_sqrt_price(upper_sqrt_price);

    let tick_spacing = i32::from_u32(pool.tick_spacing);
    let upper_tick = i32::sub(upper_tick, i32::mod(upper_tick, tick_spacing));
    let lower_tick = i32::sub(lower_tick, i32::mod(lower_tick, tick_spacing));

    (lower_tick, upper_tick)
}

// --- Package Functions ---

public(package) fun create<X, Y>(
    tick_spacing: u32,
    swap_fee_rate: u64,
    flash_loan_fee_rate: u64,
    protocol_fee_share: u64,
    protocol_flash_loan_fee_share: u64,
    ctx: &mut TxContext,
): Pool<X, Y> {
    Pool<X, Y> {
        id: object::new(ctx),
        type_x: type_name::get<X>(),
        type_y: type_name::get<Y>(),
        sqrt_price: 0,
        tick_index: i32::zero(),
        observation_index: 0,
        observation_cardinality: 0,
        observation_cardinality_next: 0,
        tick_spacing: tick_spacing,
        max_liquidity_per_tick: tick::tick_spacing_to_max_liquidity_per_tick(tick_spacing),
        fee_growth_global_x: 0,
        fee_growth_global_y: 0,
        // fee configs
        swap_fee_rate: swap_fee_rate,
        flash_loan_fee_rate: flash_loan_fee_rate,
        protocol_fee_share: protocol_fee_share,
        protocol_flash_loan_fee_share: protocol_flash_loan_fee_share,
        protocol_fee_x: 0,
        protocol_fee_y: 0,
        liquidity: 0,
        ticks: table::new<I32, TickInfo>(ctx),
        tick_bitmap: table::new<I32, u256>(ctx),
        observations: vector::empty<Observation>(),
        reward_infos: vector::empty<PoolRewardInfo>(),
        reserve_x: balance::zero<X>(),
        reserve_y: balance::zero<Y>(),
    }
}

public(package) fun toggle_trading<X, Y>(_: &AdminCap, pool: &mut Pool<X, Y>, val: bool) {
    if (df::exists_(&pool.id, constants::pool_trading_enabled_df_key())) {
        let mut enabled = df::borrow_mut<vector<u8>, bool>(
            &mut pool.id,
            constants::pool_trading_enabled_df_key(),
        );
        *enabled = val;
    } else {
        df::add<vector<u8>, bool>(&mut pool.id, constants::pool_trading_enabled_df_key(), val);
    };

    let toggle_trading_event = ToggleTradingEvent {
        pool_id: object::id(pool),
        toggle_trading: val,
    };
    event::emit(toggle_trading_event);
}

public(package) fun assert_trading_enabled<X, Y>(pool: &Pool<X, Y>) {
    let enabled = if (df::exists_(&pool.id, constants::pool_trading_enabled_df_key())) {
        *df::borrow<vector<u8>, bool>(&pool.id, constants::pool_trading_enabled_df_key())
    } else {
        true
    };

    assert!(enabled, error::trading_disabled());
}

public fun pause<X, Y>(acl: &Acl, pool: &mut Pool<X, Y>, val: bool, ctx: &TxContext) {
    assert!(app::get_pool_admin(acl) == tx_context::sender(ctx), error::not_authorised());

    if (df::exists_(&pool.id, constants::is_pause_df_key())) {
        let mut paused = df::borrow_mut<vector<u8>, bool>(
            &mut pool.id,
            constants::is_pause_df_key(),
        );
        *paused = val;
    } else {
        df::add<vector<u8>, bool>(&mut pool.id, constants::is_pause_df_key(), val);
    };

    let _pool_paused_event = PoolPausedEvent {
        sender: tx_context::sender(ctx),
        pool_id: object::id(pool),
        type_x: pool.type_x,
        type_y: pool.type_y,
        paused: val,
    };
    event::emit<PoolPausedEvent>(_pool_paused_event);
}

public(package) fun assert_not_pause<X, Y>(pool: &Pool<X, Y>) {
    let paused = if (df::exists_(&pool.id, constants::is_pause_df_key())) {
        *df::borrow<vector<u8>, bool>(&pool.id, constants::is_pause_df_key())
    } else {
        false
    };

    assert!(!paused, error::pool_is_pause());
}

public fun set_min_tick_range_factor<X, Y>(
    acl: &Acl,
    pool: &mut Pool<X, Y>,
    min_tick_range_factor: u32,
    version: &Version,
    ctx: &TxContext,
) {
    assert!(app::get_pool_admin(acl) == tx_context::sender(ctx), error::not_authorised());

    version::assert_supported_version(version);
    assert_not_pause(pool);
    assert!(
        min_tick_range_factor > 0 && min_tick_range_factor < 100,
        error::invalid_min_tick_range_factor(),
    );

    let key = MinTickRangeDfKey {};
    if (df::exists_<MinTickRangeDfKey>(&pool.id, key)) {
        let stored = df::borrow_mut<MinTickRangeDfKey, u32>(&mut pool.id, key);
        *stored = min_tick_range_factor;
    } else {
        df::add<MinTickRangeDfKey, u32>(&mut pool.id, key, min_tick_range_factor);
    };

    let _set_min_tick_range_factor_event = SetMinTickRangeFactorEvent {
        sender: tx_context::sender(ctx),
        pool_id: object::id(pool),
        min_tick_range_factor,
    };
    event::emit<SetMinTickRangeFactorEvent>(_set_min_tick_range_factor_event);
}

public(package) fun add_liquidity<X, Y>(
    pool: &mut Pool<X, Y>,
    position: &mut Position,
    mut balance_x: Balance<X>,
    mut balance_y: Balance<Y>,
    clock: &Clock,
): (u64, u64, u128, Balance<X>, Balance<Y>) {
    verify_pool<X, Y>(pool, position::pool_id(position));
    // [1] calculate liquidity delta from supplied amounts.
    // get current price, lower/upper ticks
    let current_sqrt_price = sqrt_price<X, Y>(pool);
    let sqrt_price_lower = tick_math::get_sqrt_price_at_tick(position::tick_lower_index(position));
    let sqrt_price_upper = tick_math::get_sqrt_price_at_tick(position::tick_upper_index(position));
    // calculate delta liquidity from amounts
    let delta_liquidity = liquidity_math::get_liquidity_for_amounts(
        current_sqrt_price,
        sqrt_price_lower,
        sqrt_price_upper,
        balance::value<X>(&balance_x),
        balance::value<Y>(&balance_y),
    );

    // [2] update pool & position for delta liquidity
    let (delta_x, delta_y) = update_data_for_delta_l<X, Y>(
        pool,
        position,
        i128::from(delta_liquidity),
        clock,
    );

    // [2] add assets to treasury
    assert!(
        balance::value(&balance_x) >= delta_x &&
            balance::value(&balance_y) >= delta_y,
        error::insufficient_funds(),
    );

    add_to_reserves<X, Y>(
        pool,
        balance::split(&mut balance_x, delta_x),
        balance::split(&mut balance_y, delta_y),
    );

    // return base amounts calc from liquidity
    (delta_x, delta_y, delta_liquidity, balance_x, balance_y)
}

public(package) fun remove_liquidity<X, Y>(
    pool: &mut Pool<X, Y>,
    position: &mut Position,
    liquidity_delta: I128,
    clock: &Clock,
): (Balance<X>, Balance<Y>) {
    verify_pool<X, Y>(pool, position::pool_id(position));
    // [1] update position
    let (delta_x, delta_y) = update_data_for_delta_l<X, Y>(
        pool,
        position,
        liquidity_delta,
        clock,
    );

    // [2] take assets from treasury
    let (balance_x, balance_y) = take_from_reserves(pool, delta_x, delta_y);

    // return assets and delta amounts.
    (balance_x, balance_y)
}

// updates pool & position for delta liquidty
// used for add/remove lp operations
// returns delta_x, delta_y corresponding to d_l
public(package) fun update_data_for_delta_l<X, Y>(
    pool: &mut Pool<X, Y>,
    position: &mut Position,
    liquidity_delta: I128,
    clock: &Clock,
): (u64, u64) {
    // [1] update reward growths.
    let reward_infos_update = update_reward_infos<X, Y>(
        pool,
        utils::to_seconds(clock::timestamp_ms(clock)),
    );

    let abs_liquidity_delta = i128::abs_u128(liquidity_delta);
    let lower_tick_index = position::tick_lower_index(position);
    let upper_tick_index = position::tick_upper_index(position);

    // [2] update ticks wen liquidity delta is non-zero
    let mut lower_flipped = false;
    let mut upper_flipped = false;

    if (abs_liquidity_delta != 0) {
        let current_timestamp = utils::to_seconds(clock::timestamp_ms(clock));
        let (tick_cumulative, seconds_per_liquidity_cumulative) = oracle::observe_single(
            &pool.observations,
            current_timestamp,
            0,
            pool.tick_index,
            pool.observation_index,
            pool.liquidity,
            pool.observation_cardinality,
        );

        lower_flipped =
            tick::update(
                &mut pool.ticks,
                lower_tick_index,
                pool.tick_index,
                liquidity_delta,
                pool.fee_growth_global_x,
                pool.fee_growth_global_y,
                reward_infos_update,
                seconds_per_liquidity_cumulative,
                tick_cumulative,
                current_timestamp,
                false,
                pool.max_liquidity_per_tick,
            );

        upper_flipped =
            tick::update(
                &mut pool.ticks,
                upper_tick_index,
                pool.tick_index,
                liquidity_delta,
                pool.fee_growth_global_x,
                pool.fee_growth_global_y,
                reward_infos_update,
                seconds_per_liquidity_cumulative,
                tick_cumulative,
                current_timestamp,
                true,
                pool.max_liquidity_per_tick,
            );

        // [3] update bitmap
        if (lower_flipped) {
            tick_bitmap::flip_tick(&mut pool.tick_bitmap, lower_tick_index, pool.tick_spacing);
        };
        if (upper_flipped) {
            tick_bitmap::flip_tick(&mut pool.tick_bitmap, upper_tick_index, pool.tick_spacing);
        };
    };

    // [4] update position
    let (
        fee_growth_inside_x,
        fee_growth_inside_y,
        reward_growth_inside,
    ) = tick::get_fee_and_reward_growths_inside(
        &pool.ticks,
        lower_tick_index,
        upper_tick_index,
        pool.tick_index,
        pool.fee_growth_global_x,
        pool.fee_growth_global_y,
        reward_infos_update,
    );
    position::update(
        position,
        liquidity_delta,
        fee_growth_inside_x,
        fee_growth_inside_y,
        reward_growth_inside,
    );

    // [5] clear ticks if lower/upper tick becomes empty post tick::update
    // tick can become empty only wen remove liquidity, hence check only for remove liquidity.
    if (mmt_v3::i128::lt(liquidity_delta, mmt_v3::i128::zero())) {
        if (lower_flipped) {
            mmt_v3::tick::clear(&mut pool.ticks, lower_tick_index);
        };
        if (upper_flipped) {
            mmt_v3::tick::clear(&mut pool.ticks, upper_tick_index);
        };
    };

    // [6] wen position is active, update oracle and pool liquidity.
    if (i32::gte(pool.tick_index, lower_tick_index) && i32::lt(pool.tick_index, upper_tick_index)) {
        // update oracle
        let (new_observation_index, new_observation_cardinality) = oracle::write(
            &mut pool.observations,
            pool.observation_index,
            utils::to_seconds(clock::timestamp_ms(clock)),
            pool.tick_index,
            pool.liquidity,
            pool.observation_cardinality,
            pool.observation_cardinality_next,
        );
        pool.observation_index = new_observation_index;
        pool.observation_cardinality = new_observation_cardinality;

        // update pool liquidity wen position is active.
        pool.liquidity = liquidity_math::add_delta(pool.liquidity, liquidity_delta);
    };

    // [7] calc delta x/y for liquidity delta
    let (delta_x, delta_y) = liquidity_math::get_amounts_for_liquidity(
        sqrt_price<X, Y>(pool),
        tick_math::get_sqrt_price_at_tick(lower_tick_index),
        tick_math::get_sqrt_price_at_tick(upper_tick_index),
        abs_liquidity_delta,
        // round down wen remove lp, else round up
        if (i128::is_neg(liquidity_delta)) false else true,
    );

    (delta_x, delta_y)
}

// collect fee for position
public(package) fun collect_fee<X, Y>(
    pool: &mut Pool<X, Y>,
    position: &mut Position,
): (Balance<X>, Balance<Y>) {
    verify_pool<X, Y>(pool, position::pool_id(position));
    let amount_x = position::owed_coin_x(position);
    let amount_y = position::owed_coin_y(position);

    position::decrease_owed_amount(position, amount_x, amount_y);
    take_from_reserves<X, Y>(pool, amount_x, amount_y)
}

// collect reward for position
public(package) fun collect_reward<X, Y, R>(
    pool: &mut Pool<X, Y>,
    position: &mut Position,
): Balance<R> {
    verify_pool<X, Y>(pool, position::pool_id(position));
    let reward_info_index = find_reward_info_index<X, Y, R>(pool);
    let amount = position::coins_owed_reward(position, reward_info_index);
    position::decrease_reward_debt(position, reward_info_index, amount);

    let custodian_key = PoolRewardCustodianDfKey<R> { dummy_field: false };
    safe_withdraw<R>(
        dynamic_field::borrow_mut<PoolRewardCustodianDfKey<R>, Balance<R>>(
            &mut pool.id,
            custodian_key,
        ),
        amount,
    )
}

// add assets to reserves
public(package) fun add_to_reserves<X, Y>(
    pool: &mut Pool<X, Y>,
    reserve_x_balance: Balance<X>,
    reserve_y_balance: Balance<Y>,
) {
    balance::join(&mut pool.reserve_x, reserve_x_balance);
    balance::join(&mut pool.reserve_y, reserve_y_balance);
}

public(package) fun take_from_reserves<X, Y>(
    pool: &mut Pool<X, Y>,
    amount_x: u64,
    amount_y: u64,
): (Balance<X>, Balance<Y>) {
    (
        safe_withdraw<X>(&mut pool.reserve_x, amount_x),
        safe_withdraw<Y>(&mut pool.reserve_y, amount_y),
    )
}

// friend getters and setters
public(package) fun ticks_mut<X, Y>(pool: &mut Pool<X, Y>): &mut Table<I32, TickInfo> {
    &mut pool.ticks
}

public(package) fun tick_bitmap_mut<X, Y>(pool: &mut Pool<X, Y>): &mut Table<I32, u256> {
    &mut pool.tick_bitmap
}

public(package) fun observations_mut<X, Y>(pool: &mut Pool<X, Y>): &mut vector<Observation> {
    &mut pool.observations
}

public(package) fun set_fee_growth_global_x<X, Y>(pool: &mut Pool<X, Y>, val: u128) {
    pool.fee_growth_global_x = val;
}

public(package) fun set_fee_growth_global_y<X, Y>(pool: &mut Pool<X, Y>, val: u128) {
    pool.fee_growth_global_y = val;
}

public(package) fun set_liquidity<X, Y>(pool: &mut Pool<X, Y>, val: u128) { pool.liquidity = val; }

public(package) fun set_sqrt_price<X, Y>(self: &mut Pool<X, Y>, val: u128) {
    self.sqrt_price = val;
}

public(package) fun set_tick_index_current<X, Y>(pool: &mut Pool<X, Y>, val: I32) {
    pool.tick_index = val;
}

public(package) fun set_observation_index<X, Y>(pool: &mut Pool<X, Y>, val: u64) {
    pool.observation_index = val;
}

public(package) fun set_observation_cardinality<X, Y>(pool: &mut Pool<X, Y>, val: u64) {
    pool.observation_cardinality = val;
}

public(package) fun set_protocol_fee_share<X, Y>(pool: &mut Pool<X, Y>, val: u64) {
    pool.protocol_fee_share = val;
}

public(package) fun set_protocol_flash_loan_fee_share<X, Y>(pool: &mut Pool<X, Y>, val: u64) {
    pool.protocol_flash_loan_fee_share = val;
}

public(package) fun set_protocol_fee_x<X, Y>(pool: &mut Pool<X, Y>, val: u64) {
    pool.protocol_fee_x = val;
}

public(package) fun set_protocol_fee_y<X, Y>(pool: &mut Pool<X, Y>, val: u64) {
    pool.protocol_fee_y = val;
}

public(package) fun set_swap_fee_rate<X, Y>(pool: &mut Pool<X, Y>, val: u64) {
    pool.swap_fee_rate = val;
}

public(package) fun set_flash_loan_fee_rate<X, Y>(pool: &mut Pool<X, Y>, val: u64) {
    pool.flash_loan_fee_rate = val;
}

public(package) fun set_ve_enabled_state<X, Y>(pool: &mut Pool<X, Y>, val: bool) {
    let key = VeEnabledDfKey {};
    assert!(is_ve_enabled(pool) != val, error::ve_state_not_changed());

    if (df::exists_<VeEnabledDfKey>(&pool.id, key)){
        let mut enabled = df::borrow_mut<VeEnabledDfKey, bool>(&mut pool.id, key);
        *enabled = val;
    }else {
        df::add(&mut pool.id, key, val);
    };

    if (val) {
        pool.protocol_fee_share = constants::protocol_fee_share_denominator();
    } else {
        pool.protocol_fee_share = constants::protocol_swap_fee_share();
    };
    event::emit<VeStateChangedEvent>(VeStateChangedEvent {
        pool_id: pool.pool_id(),
        ve_enabled: val,
    });
}

public(package) fun default_reward_info(
    reward_coin_type: TypeName,
    last_update_time: u64,
): PoolRewardInfo {
    PoolRewardInfo {
        reward_coin_type,
        last_update_time: last_update_time,
        ended_at_seconds: last_update_time,
        total_reward: 0,
        total_reward_allocated: 0,
        reward_per_seconds: 0,
        reward_growth_global: 0,
    }
}

public(package) fun add_reward_info<X, Y, R>(
    pool: &mut Pool<X, Y>,
    reward_info: PoolRewardInfo,
    _ctx: &TxContext,
) {
    let custodian_key = PoolRewardCustodianDfKey<R> { dummy_field: false };
    dynamic_field::add<PoolRewardCustodianDfKey<R>, Balance<R>>(
        &mut pool.id,
        custodian_key,
        balance::zero<R>(),
    );
    vector::push_back(&mut pool.reward_infos, reward_info);
}

public(package) fun increase_observation_cardinality_next<X, Y>(
    pool: &mut Pool<X, Y>,
    new_cardinality: u64,
    ctx: &TxContext,
) {
    let current_cardinality_next = pool.observation_cardinality_next;
    let updated_cardinality_next = oracle::grow(
        &mut pool.observations,
        current_cardinality_next,
        new_cardinality,
    );
    pool.observation_cardinality_next = updated_cardinality_next;
    event::emit(ObservationCardinalityUpdatedEvent {
        sender: tx_context::sender(ctx),
        pool_id: object::id(pool),
        observation_cardinality_next_old: current_cardinality_next,
        observation_cardinality_next_new: updated_cardinality_next,
    });
}

public(package) fun update_reward_infos<X, Y>(
    pool: &mut Pool<X, Y>,
    current_time: u64,
): vector<u128> {
    let mut reward_growth_global_updates = vector::empty<u128>();
    let mut index = 0;
    while (index < vector::length<PoolRewardInfo>(&pool.reward_infos)) {
        let reward_info = vector::borrow_mut<PoolRewardInfo>(&mut pool.reward_infos, index);
        index = index + 1;
        if (current_time > reward_info.last_update_time) {
            let min_time = math::min(current_time, reward_info.ended_at_seconds);
            if (pool.liquidity != 0 && min_time > reward_info.last_update_time) {
                let time_diff = (min_time - reward_info.last_update_time) as u128;
                let reward = full_math_u128::full_mul(time_diff, reward_info.reward_per_seconds);
                reward_info.reward_growth_global =
                    mmt_v3::math_u128::wrapping_add(
                        reward_info.reward_growth_global,
                        (reward / (pool.liquidity as u256)) as u128,
                    );
                reward_info.total_reward_allocated =
                    reward_info.total_reward_allocated + ((reward / (mmt_v3::constants::q64() as u256)) as u64);
            };
            reward_info.last_update_time = current_time;
        };
        vector::push_back<u128>(
            &mut reward_growth_global_updates,
            reward_info.reward_growth_global,
        );
    };
    reward_growth_global_updates
}

public(package) fun update_pool_reward_emission<X, Y, R>(
    pool: &mut Pool<X, Y>,
    additional_balance: Balance<R>,
    additional_seconds: u64,
    tx_context: &TxContext,
): (u64, u64) {
    let pool_id = object::id<Pool<X, Y>>(pool);
    let reward_index = find_reward_info_index<X, Y, R>(pool);
    let reward_info = vector::borrow_mut<PoolRewardInfo>(&mut pool.reward_infos, reward_index);
    let new_end_time = reward_info.ended_at_seconds + additional_seconds;
    assert!(new_end_time > reward_info.last_update_time, error::invalid_last_update_time());

    reward_info.total_reward = reward_info.total_reward + balance::value<R>(&additional_balance);
    reward_info.ended_at_seconds = new_end_time;
    reward_info.reward_per_seconds =
        full_math_u128::mul_div_floor(
            (reward_info.total_reward - reward_info.total_reward_allocated) as u128,
            mmt_v3::constants::q64() as u128,
            (reward_info.ended_at_seconds - reward_info.last_update_time) as u128,
        );

    let custodian_key = PoolRewardCustodianDfKey<R> { dummy_field: false };
    balance::join<R>(
        dynamic_field::borrow_mut<PoolRewardCustodianDfKey<R>, Balance<R>>(
            &mut pool.id,
            custodian_key,
        ),
        additional_balance,
    );

    let update_event = UpdatePoolRewardEmissionEvent {
        sender: tx_context::sender(tx_context),
        pool_id: pool_id,
        reward_coin_type: reward_info.reward_coin_type,
        total_reward: reward_info.total_reward,
        ended_at_seconds: reward_info.ended_at_seconds,
        reward_per_seconds: reward_info.reward_per_seconds,
    };

    event::emit<UpdatePoolRewardEmissionEvent>(update_event);

    (new_end_time - additional_seconds, new_end_time)
}

fun find_reward_info_index<X, Y, R>(pool: &Pool<X, Y>): u64 {
    let mut index = 0u64;
    let mut found = false;
    let mut current_index = index;
    while (current_index < vector::length(&pool.reward_infos)) {
        if (
            vector::borrow(&pool.reward_infos, current_index).reward_coin_type == type_name::get<R>()
        ) {
            index = current_index;
            found = true;
            break
        };
        current_index = current_index + 1;
    };

    assert!(found, error::reward_index_not_found());

    index
}

fun safe_withdraw<X>(balance: &mut Balance<X>, amount: u64): Balance<X> {
    let balance_val = balance::value<X>(balance);
    balance::split<X>(balance, math::min(amount, balance_val))
}
