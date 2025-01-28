# SPDX-License-Identifier: MIT
# pragma version ~=0.4.0

from snekmate.auth import ownable
initializes: ownable

from interfaces import ITroveManager
from interfaces import ILUSDToken
from interfaces import IStabilityPool
from interfaces import IActivePool
from interfaces import IDefaultPool
from interfaces import IPool
from interfaces import IPriceFeed
from interfaces import ISortedTroves
from interfaces import ILQTYToken
from interfaces import ILQTYStaking
from interfaces import ICollSurplusPool

import math
import base

NAME: constant(String[20]) = "TroveManager"

# --- Connected contract declarations ---
borrower_operations_address: public(address)
active_pool: public(IActivePool)
default_pool: public(IDefaultPool)
price_feed: public(IPriceFeed)
stability_pool: public(IStabilityPool)
gas_pool_address: address
coll_surplus_pool: ICollSurplusPool
gov_staking: public(ILQTYStaking)
gov_staking_address: public(address)
lusd_token: public(ILUSDToken)
gov_token: public(ILQTYToken)
sorted_troves: public(ISortedTroves)


SECONDS_IN_ONE_MINUTE: constant(uint256) = 60
MINUTE_DECAY_FACTOR: constant(uint256) = 999037758833783000
REDEMPTION_FEE_FLOOR: constant(uint256) = base.DECIMAL_PRECISION // 1000 * 5
MAX_BORROWING_FEE: constant(uint256) = base.DECIMAL_PRECISION // 100 * 5
BOOTSTRAP_PERIOD: constant(uint256) = 14 * 86400
BETA: constant(uint256) = 2

base_rate: public(uint256)
last_fee_operation_time: public(uint256)

flag Status:
    NON_EXISTENT
    ACTIVE
    CLOSED_BY_OWNER
    CLOSED_BY_LIQUIDATION
    CLOSED_BY_REDEMPTION

struct Trove:
    debt: uint256
    coll: uint256
    stake: uint256
    status: Status
    array_index: uint128

troves: public(HashMap[address, Trove])
total_stakes: public(uint256)
total_stakes_snapshot: public(uint256)
total_collateral_snapshot: public(uint256)

l_eth: public(uint256)
l_lusd_debt: public(uint256)

struct RewardSnapshot:
    eth: uint256
    lusd_debt: uint256

reward_snapshots: public(HashMap[address, RewardSnapshot])
trove_owners: public(DynArray[address, 1000])

last_eth_error_redistribution: public(uint256)
last_lusd_debt_error_redistribution: public(uint256)

struct LocalVariablesOuterLiquidationFunction:
    price: uint256
    lusd_in_stab_pool: uint256
    recovery_mode_at_start: bool
    liquidated_debt: uint256
    liquidated_coll: uint256

struct LocalVariablesInnerSingleLiquidateFunction:
    coll_to_liquidate: uint256
    pending_debt_reward: uint256
    pending_coll_reward: uint256

struct LocalVariablesLiquidationSequence:
    remaining_lusd_in_stab_pool: uint256
    i: uint256
    icr: uint256
    user: address
    back_to_normal_mode: bool
    entire_system_debt: uint256
    entire_system_coll: uint256

struct LiquidationValues:
    entire_trove_debt: uint256
    entire_trove_coll: uint256
    coll_gas_compensation: uint256
    lusd_gas_compensation: uint256
    debt_to_offset: uint256
    coll_to_send_to_sp: uint256
    debt_to_redistribute: uint256
    coll_to_redistribute: uint256
    coll_surplus: uint256

struct LiquidationTotals:
    total_coll_in_sequence: uint256
    total_debt_in_sequence: uint256
    total_coll_gas_compensation: uint256
    total_lusd_gas_compensation: uint256
    total_debt_to_offset: uint256
    total_coll_to_send_to_sp: uint256
    total_debt_to_redistribute: uint256
    total_coll_to_redistribute: uint256
    total_coll_surplus: uint256

struct ContractsCache:
    active_pool: IActivePool
    default_pool: IDefaultPool
    lusd_token: ILUSDToken
    gov_staking: ILQTYStaking
    sorted_troves: ISortedTroves
    coll_surplus_pool: ICollSurplusPool
    gas_pool_address: address

struct RedemptionTotals:
    remaining_rd: uint256
    total_lusd_to_redeem: uint256
    total_eth_drawn: uint256
    eth_fee: uint256
    eth_to_send_to_redeemer: uint256
    decayed_base_rate: uint256
    price: uint256
    total_lusd_supply_at_start: uint256

struct SingleRedemptionValues:
    lusd_lot: uint256
    eth_lot: uint256
    cancelled_partial: bool

event BorrowerOperationsAddressChanged:
    new_address: address
event PriceFeedAddressChanged:
    new_address: address
event RDTokenAddressChanged:
    new_address: address
event ActivePoolAddressChanged:
    new_address: address
event DefaultPoolAddressChanged:
    new_address: address
event StabilityPoolAddressChanged:
    new_address: address
event GasPoolAddressChanged:
    new_address: address
event CollSurplusPoolAddressChanged:
    new_address: address
event SortedTrovesAddressChanged:
    new_address: address
event LQTYTokenAddressChanged:
    new_address: address
event LQTYStakingAddressChanged:
    new_address: address
event Liquidation:
    liquidated_debt: uint256
    liquidated_coll: uint256
    coll_gas_compensation: uint256
    lusd_gas_compensation: uint256
event Redemption:
    attempted_lusd_amount: uint256
    actual_lusd_amount: uint256
    eth_sent: uint256
    eth_fee: uint256
event TroveUpdated:
    borrower: address
    debt: uint256
    coll: uint256
    stake: uint256
    operation: TroveManagerOperation
event TroveLiquidated:
    borrower: address
    debt: uint256
    coll: uint256
    operation: TroveManagerOperation
event BaseRateUpdated:
    base_rate: uint256
event LastFeeOpTimeUpdated:
    last_fee_op_time: uint256
event TotalStakesUpdated:
    new_total_stakes: uint256
event SystemSnapshotsUpdated:
    total_stakes_snapshot: uint256
    total_collateral_snapshot: uint256
event LTermsUpdated:
    l_eth: uint256
    l_lusd_debt: uint256
event TroveSnapshotsUpdated:
    l_eth: uint256
    l_lusd_debt: uint256
event TroveIndexUpdated:
    borrower: address
    new_index: uint128

flag TroveManagerOperation:
    APPLY_PENDING_REWARDS
    LIQUIDATE_IN_NORMAL_MODE
    LIQUIDATE_IN_RECOVERY_MODE
    REDEEM_COLLATERAL

@deploy
def __init__():
    ownable.__init__()

@external
def set_addresses(
    borrower_operations_address: address,
    active_pool_address: address,
    default_pool_address: address,
    stability_pool_address: address,
    gas_pool_address: address,
    coll_surplus_pool_address: address,
    price_feed_address: address,
    lusd_token_address: address,
    sorted_troves_address: address,
    gov_token_address: address,
    gov_staking_address: address
):
    ownable._check_owner()

    self.borrower_operations_address = borrower_operations_address
    self.active_pool = IActivePool(active_pool_address)
    self.default_pool = IDefaultPool(default_pool_address)
    self.stability_pool = IStabilityPool(stability_pool_address)
    self.gas_pool_address = gas_pool_address
    self.coll_surplus_pool = ICollSurplusPool(coll_surplus_pool_address)
    self.price_feed = IPriceFeed(price_feed_address)
    self.lusd_token = ILUSDToken(lusd_token_address)
    self.sorted_troves = ISortedTroves(sorted_troves_address)
    self.gov_token = ILQTYToken(gov_token_address)
    self.gov_staking = ILQTYStaking(gov_staking_address)

    log BorrowerOperationsAddressChanged(borrower_operations_address)
    log ActivePoolAddressChanged(active_pool_address)
    log DefaultPoolAddressChanged(default_pool_address)
    log StabilityPoolAddressChanged(stability_pool_address)
    log GasPoolAddressChanged(gas_pool_address)
    log CollSurplusPoolAddressChanged(coll_surplus_pool_address)
    log PriceFeedAddressChanged(price_feed_address)
    log RDTokenAddressChanged(lusd_token_address)
    log SortedTrovesAddressChanged(sorted_troves_address)
    log LQTYTokenAddressChanged(gov_token_address)
    log LQTYStakingAddressChanged(gov_staking_address)

    ownable.owner = empty(address)
    #ownable._transfer_ownership(empty(address))

@external
@view
def get_trove_owners_count() -> uint256:
    return len(self.trove_owners)

@external
@view
def get_trove_from_trove_owners_array(index: uint256) -> address:
    return self.trove_owners[index]

@external
def liquidate(borrower: address):
    assert self.troves[borrower].status == Status.ACTIVE
    borrowers: DynArray[address, 1] = [borrower]
    self._batch_liquidate_troves(borrowers)

@internal
def _liquidate_normal_mode(
    active_pool: IActivePool,
    default_pool: IDefaultPool,
    borrower: address,
    lusd_in_stab_pool: uint256
) -> LiquidationValues:
    vars: LocalVariablesInnerSingleLiquidateFunction = empty(LocalVariablesInnerSingleLiquidateFunction)
    single_liquidation : LiquidationValues = empty(LiquidationValues)
    (
        single_liquidation.entire_trove_debt,
        single_liquidation.entire_trove_coll,
        vars.pending_debt_reward,
        vars.pending_coll_reward
    ) = self._get_entire_debt_and_coll(borrower)

    self._move_pending_trove_rewards_to_active_pool(active_pool, default_pool, vars.pending_debt_reward, vars.pending_coll_reward)
    self._remove_stake(borrower)

    single_liquidation.coll_gas_compensation = base._get_coll_gas_compensation(single_liquidation.entire_trove_coll)
    single_liquidation.lusd_gas_compensation = base.RD_GAS_COMPENSATION
    coll_to_liquidate : uint256 = single_liquidation.entire_trove_coll - single_liquidation.coll_gas_compensation

    (
        single_liquidation.debt_to_offset,
        single_liquidation.coll_to_send_to_sp,
        single_liquidation.debt_to_redistribute,
        single_liquidation.coll_to_redistribute
    ) = self._get_offset_and_redistribution_vals(single_liquidation.entire_trove_debt, coll_to_liquidate, lusd_in_stab_pool)

    self._close_trove(borrower, Status.CLOSED_BY_LIQUIDATION)
    log TroveLiquidated(borrower, single_liquidation.entire_trove_debt, single_liquidation.entire_trove_coll, TroveManagerOperation.LIQUIDATE_IN_NORMAL_MODE)
    log TroveUpdated(borrower, 0, 0, 0, TroveManagerOperation.LIQUIDATE_IN_NORMAL_MODE)
    return single_liquidation

@internal
def _liquidate_recovery_mode(
    active_pool: IActivePool,
    default_pool: IDefaultPool,
    borrower: address,
    icr: uint256,
    lusd_in_stab_pool: uint256,
    tcr: uint256,
    price: uint256
) -> LiquidationValues:
    vars: LocalVariablesInnerSingleLiquidateFunction = empty(LocalVariablesInnerSingleLiquidateFunction)
    if len(self.trove_owners) <= 1:
        return empty(LiquidationValues)

    single_liquidation : LiquidationValues = empty(LiquidationValues) 
    (
        single_liquidation.entire_trove_debt,
        single_liquidation.entire_trove_coll,
        vars.pending_debt_reward,
        vars.pending_coll_reward
    ) = self._get_entire_debt_and_coll(borrower)

    single_liquidation.coll_gas_compensation = base._get_coll_gas_compensation(single_liquidation.entire_trove_coll)
    single_liquidation.lusd_gas_compensation = base.RD_GAS_COMPENSATION
    vars.coll_to_liquidate = single_liquidation.entire_trove_coll - single_liquidation.coll_gas_compensation

    if icr <= base.one_hundred_pct:
        self._move_pending_trove_rewards_to_active_pool(active_pool, default_pool, vars.pending_debt_reward, vars.pending_coll_reward)
        self._remove_stake(borrower)

        single_liquidation.debt_to_offset = 0
        single_liquidation.coll_to_send_to_sp = 0
        single_liquidation.debt_to_redistribute = single_liquidation.entire_trove_debt
        single_liquidation.coll_to_redistribute = vars.coll_to_liquidate

    elif icr > base.one_hundred_pct and icr < base.MCR:
        self._move_pending_trove_rewards_to_active_pool(active_pool, default_pool, vars.pending_debt_reward, vars.pending_coll_reward)
        self._remove_stake(borrower)

        (
            single_liquidation.debt_to_offset,
            single_liquidation.coll_to_send_to_sp,
            single_liquidation.debt_to_redistribute,
            single_liquidation.coll_to_redistribute
        ) = self._get_offset_and_redistribution_vals(single_liquidation.entire_trove_debt, vars.coll_to_liquidate, lusd_in_stab_pool)
    
    elif icr >= base.MCR and icr < tcr and single_liquidation.entire_trove_debt <= lusd_in_stab_pool:
        self._move_pending_trove_rewards_to_active_pool(active_pool, default_pool, vars.pending_debt_reward, vars.pending_coll_reward)
        assert lusd_in_stab_pool != 0
        self._remove_stake(borrower)
        single_liquidation = self._get_capped_offset_vals(single_liquidation.entire_trove_debt, single_liquidation.entire_trove_coll, price)
    
    self._close_trove(borrower, Status.CLOSED_BY_LIQUIDATION)
    return single_liquidation

@internal
@pure
def _get_offset_and_redistribution_vals(
    debt: uint256,
    coll: uint256,
    lusd_in_stab_pool: uint256
) -> (uint256, uint256, uint256, uint256):
    debt_to_offset: uint256 = 0
    coll_to_send_to_sp: uint256 = 0
    debt_to_redistribute: uint256 = 0
    coll_to_redistribute: uint256 = 0

    if lusd_in_stab_pool > 0:
        debt_to_offset = min(debt, lusd_in_stab_pool)
        coll_to_send_to_sp = (coll * debt_to_offset) // debt
        debt_to_redistribute = debt - debt_to_offset
        coll_to_redistribute = coll - coll_to_send_to_sp
    else:
        debt_to_offset = 0
        coll_to_send_to_sp = 0
        debt_to_redistribute = debt
        coll_to_redistribute = coll
    return debt_to_offset, coll_to_send_to_sp, debt_to_redistribute, coll_to_redistribute

@internal
@pure
def _get_capped_offset_vals(
    entire_trove_debt: uint256,
    entire_trove_coll: uint256,
    price: uint256
) -> LiquidationValues:
    single_liquidation: LiquidationValues = empty(LiquidationValues)
    single_liquidation.entire_trove_debt = entire_trove_debt
    single_liquidation.entire_trove_coll = entire_trove_coll
    capped_coll_portion: uint256 = (entire_trove_debt * base.MCR) // price

    single_liquidation.coll_gas_compensation = base._get_coll_gas_compensation(capped_coll_portion)
    single_liquidation.lusd_gas_compensation = base.RD_GAS_COMPENSATION

    single_liquidation.debt_to_offset = entire_trove_debt
    single_liquidation.coll_to_send_to_sp = capped_coll_portion - single_liquidation.coll_gas_compensation
    single_liquidation.coll_surplus = entire_trove_coll - capped_coll_portion
    single_liquidation.debt_to_redistribute = 0
    single_liquidation.coll_to_redistribute = 0
    return single_liquidation

@internal
@view
def _get_tcr(price: uint256) -> uint256:
    entire_system_coll: uint256 = self._get_entire_system_coll()
    entire_system_debt: uint256 = self._get_entire_system_debt()
    return math._compute_cr(entire_system_coll, entire_system_debt, price)

@internal
@view
def _check_recovery_mode(price: uint256) -> bool:
    tcr: uint256 = self._get_tcr(price)
    return tcr < base.CCR

@external
def liquidate_troves(n: uint256):
    contracts_cache: ContractsCache = ContractsCache(
        active_pool=self.active_pool,
        default_pool=self.default_pool,
        lusd_token=ILUSDToken(empty(address)),
        gov_staking=ILQTYStaking(empty(address)),
        sorted_troves=self.sorted_troves,
        coll_surplus_pool=ICollSurplusPool(empty(address)),
        gas_pool_address=empty(address)
    )
    stability_pool_cached: IStabilityPool = self.stability_pool

    vars: LocalVariablesOuterLiquidationFunction = empty(LocalVariablesOuterLiquidationFunction)
    totals: LiquidationTotals = empty(LiquidationTotals)

    vars.price = extcall self.price_feed.fetch_price()
    vars.lusd_in_stab_pool = staticcall stability_pool_cached.get_total_lusd_deposits()
    vars.recovery_mode_at_start = self._check_recovery_mode(vars.price)

    if vars.recovery_mode_at_start:
        totals = self._get_totals_from_liquidate_troves_sequence_recovery_mode(
            contracts_cache, vars.price, vars.lusd_in_stab_pool, n
        )
    else:
        totals = self._get_totals_from_liquidate_troves_sequence_normal_mode(
            contracts_cache.active_pool, contracts_cache.default_pool, vars.price, vars.lusd_in_stab_pool, n
        )
    assert totals.total_debt_in_sequence > 0, "TroveManager: nothing to liquidate"

    extcall stability_pool_cached.offset(totals.total_debt_to_offset, totals.total_coll_to_send_to_sp)
    self._redistribute_debt_and_coll(
        contracts_cache.active_pool,
        contracts_cache.default_pool,
        totals.total_debt_to_redistribute,
        totals.total_coll_to_redistribute
    )

    if totals.total_coll_surplus > 0:
        extcall contracts_cache.active_pool.send_eth(self.coll_surplus_pool.address, totals.total_coll_surplus)

    self._update_system_snapshots_exclude_coll_remainder(
        contracts_cache.active_pool, totals.total_coll_gas_compensation
    )

    vars.liquidated_debt = totals.total_debt_in_sequence
    vars.liquidated_coll = (
        totals.total_coll_in_sequence - totals.total_coll_gas_compensation - totals.total_coll_surplus
    )
    log Liquidation(vars.liquidated_debt, vars.liquidated_coll, totals.total_coll_gas_compensation, totals.total_lusd_gas_compensation)

    self._send_gas_compensation(
        contracts_cache.active_pool, msg.sender, totals.total_lusd_gas_compensation, totals.total_coll_gas_compensation
    )

@external
@view
def get_entire_system_coll() -> uint256:
    return self._get_entire_system_coll()

@internal
@view
def _get_entire_system_coll() -> uint256:
    active_coll: uint256 = staticcall self.active_pool.get_eth()
    liquidated_coll: uint256 = staticcall self.default_pool.get_eth()
    return active_coll + liquidated_coll

@external
@view
def get_entire_system_debt() -> uint256:
    return self._get_entire_system_debt()

@internal
@view
def _get_entire_system_debt() -> uint256:
    active_debt: uint256 = staticcall self.active_pool.get_lusd_debt()
    closed_debt: uint256 = staticcall self.default_pool.get_lusd_debt()
    return active_debt + closed_debt

@internal
def _get_totals_from_liquidate_troves_sequence_recovery_mode(
    contracts_cache: ContractsCache,
    price: uint256,
    lusd_in_stab_pool: uint256,
    n: uint256
) -> LiquidationTotals:
    vars: LocalVariablesLiquidationSequence = empty(LocalVariablesLiquidationSequence)
    single_liquidation: LiquidationValues = empty(LiquidationValues)
    totals: LiquidationTotals = empty(LiquidationTotals)

    vars.remaining_lusd_in_stab_pool = lusd_in_stab_pool
    vars.back_to_normal_mode = False
    vars.entire_system_debt = self._get_entire_system_debt()
    vars.entire_system_coll = self._get_entire_system_coll()

    vars.user = staticcall contracts_cache.sorted_troves.get_last()
    first_user: address = staticcall contracts_cache.sorted_troves.get_first()

    for _: uint256 in range(n, bound=base.MAX_TROVES):
        if vars.user == first_user:
            break

        next_user: address = staticcall contracts_cache.sorted_troves.get_prev(vars.user)
        vars.icr = self._get_current_icr(vars.user, price)

        if not vars.back_to_normal_mode:
            if vars.icr >= base.MCR and vars.remaining_lusd_in_stab_pool == 0:
                break

            tcr: uint256 = math._compute_cr(vars.entire_system_coll, vars.entire_system_debt, price)

            single_liquidation = self._liquidate_recovery_mode(
                contracts_cache.active_pool,
                contracts_cache.default_pool,
                vars.user,
                vars.icr,
                vars.remaining_lusd_in_stab_pool,
                tcr,
                price
            )

            vars.remaining_lusd_in_stab_pool -= single_liquidation.debt_to_offset
            vars.entire_system_debt -= single_liquidation.debt_to_offset
            vars.entire_system_coll -= (
                single_liquidation.coll_to_send_to_sp +
                single_liquidation.coll_gas_compensation +
                single_liquidation.coll_surplus
            )

            totals = self._add_liquidation_values_to_totals(totals, single_liquidation)
            vars.back_to_normal_mode = not self._check_potential_recovery_mode(vars.entire_system_coll, vars.entire_system_debt, price)

        elif vars.back_to_normal_mode and vars.icr < base.MCR:
            single_liquidation = self._liquidate_normal_mode(
                contracts_cache.active_pool,
                contracts_cache.default_pool,
                vars.user,
                vars.remaining_lusd_in_stab_pool
            )

            vars.remaining_lusd_in_stab_pool -= single_liquidation.debt_to_offset
            totals = self._add_liquidation_values_to_totals(totals, single_liquidation)

        else:
            break

        vars.user = next_user
    return totals

@internal
def _get_totals_from_liquidate_troves_sequence_normal_mode(
    active_pool: IActivePool,
    default_pool: IDefaultPool,
    price: uint256,
    lusd_in_stab_pool: uint256,
    n: uint256
) -> LiquidationTotals:
    vars: LocalVariablesLiquidationSequence = empty(LocalVariablesLiquidationSequence)
    single_liquidation: LiquidationValues = empty(LiquidationValues)
    sorted_troves_cached: ISortedTroves = self.sorted_troves

    totals: LiquidationTotals = empty(LiquidationTotals)

    vars.remaining_lusd_in_stab_pool = lusd_in_stab_pool

    for _: uint256 in range(n, bound=base.MAX_TROVES):
        vars.user = staticcall sorted_troves_cached.get_last()
        vars.icr = self._get_current_icr(vars.user, price)

        if vars.icr < base.MCR:
            single_liquidation = self._liquidate_normal_mode(active_pool, default_pool, vars.user, vars.remaining_lusd_in_stab_pool)
            vars.remaining_lusd_in_stab_pool -= single_liquidation.debt_to_offset
            totals = self._add_liquidation_values_to_totals(totals, single_liquidation)
        else:
            break
    return totals

@external
def batch_liquidate_troves(trove_array: DynArray[address, 1000]):
    self._batch_liquidate_troves(trove_array)

@internal
def _batch_liquidate_troves(trove_array: DynArray[address, 1000]):
    assert len(trove_array) != 0, "TroveManager: Calldata address array must not be empty"

    active_pool_cached: IActivePool = self.active_pool
    default_pool_cached: IDefaultPool = self.default_pool
    stability_pool_cached: IStabilityPool = self.stability_pool

    vars: LocalVariablesOuterLiquidationFunction = empty(LocalVariablesOuterLiquidationFunction)
    totals: LiquidationTotals = empty(LiquidationTotals)

    vars.price = extcall self.price_feed.fetch_price()
    vars.lusd_in_stab_pool = staticcall stability_pool_cached.get_total_lusd_deposits()
    vars.recovery_mode_at_start = self._check_recovery_mode(vars.price)

    if vars.recovery_mode_at_start:
        totals = self._get_total_from_batch_liquidate_recovery_mode(active_pool_cached, default_pool_cached, vars.price, vars.lusd_in_stab_pool, trove_array)
    else:
        totals = self._get_totals_from_batch_liquidate_normal_mode(active_pool_cached, default_pool_cached, vars.price, vars.lusd_in_stab_pool, trove_array)

    assert totals.total_debt_in_sequence > 0, "TroveManager: nothing to liquidate"

    extcall stability_pool_cached.offset(totals.total_debt_to_offset, totals.total_coll_to_send_to_sp)
    self._redistribute_debt_and_coll(active_pool_cached, default_pool_cached, totals.total_debt_to_redistribute, totals.total_coll_to_redistribute)

    if totals.total_coll_surplus > 0:
        extcall active_pool_cached.send_eth(self.coll_surplus_pool.address, totals.total_coll_surplus)

    self._update_system_snapshots_exclude_coll_remainder(active_pool_cached, totals.total_coll_gas_compensation)

    vars.liquidated_debt = totals.total_debt_in_sequence
    vars.liquidated_coll = totals.total_coll_in_sequence - totals.total_coll_gas_compensation - totals.total_coll_surplus

    log Liquidation(vars.liquidated_debt, vars.liquidated_coll, totals.total_coll_gas_compensation, totals.total_lusd_gas_compensation)

    self._send_gas_compensation(active_pool_cached, msg.sender, totals.total_lusd_gas_compensation, totals.total_coll_gas_compensation)

def _get_total_from_batch_liquidate_recovery_mode(
    active_pool: IActivePool,
    default_pool: IDefaultPool,
    price: uint256,
    lusd_in_stab_pool: uint256,
    trove_array: DynArray[address, 1000]
) -> LiquidationTotals:
    vars: LocalVariablesLiquidationSequence = empty(LocalVariablesLiquidationSequence)
    single_liquidation: LiquidationValues = empty(LiquidationValues)
    totals: LiquidationTotals = empty(LiquidationTotals)

    vars.remaining_lusd_in_stab_pool = lusd_in_stab_pool
    vars.back_to_normal_mode = False
    vars.entire_system_debt = self._get_entire_system_debt()
    vars.entire_system_coll = self._get_entire_system_coll()

    for i: uint256 in range(len(trove_array), bound=base.MAX_TROVES):
        vars.user = trove_array[i]

        if self.troves[vars.user].status != Status.ACTIVE:
            continue

        vars.icr = self._get_current_icr(vars.user, price)

        if not vars.back_to_normal_mode:
            if vars.icr >= base.MCR and vars.remaining_lusd_in_stab_pool == 0:
                continue

            tcr: uint256 = math._compute_cr(vars.entire_system_coll, vars.entire_system_debt, price)

            single_liquidation = self._liquidate_recovery_mode(
                active_pool, default_pool, vars.user, vars.icr, vars.remaining_lusd_in_stab_pool, tcr, price
            )

            vars.remaining_lusd_in_stab_pool -= single_liquidation.debt_to_offset
            vars.entire_system_debt -= single_liquidation.debt_to_offset
            vars.entire_system_coll -= (
                single_liquidation.coll_to_send_to_sp +
                single_liquidation.coll_gas_compensation +
                single_liquidation.coll_surplus
            )

            totals = self._add_liquidation_values_to_totals(totals, single_liquidation)

            vars.back_to_normal_mode = not self._check_potential_recovery_mode(
                vars.entire_system_coll, vars.entire_system_debt, price
            )
        elif vars.back_to_normal_mode and vars.icr < base.MCR:
            single_liquidation = self._liquidate_normal_mode(active_pool, default_pool, vars.user, vars.remaining_lusd_in_stab_pool)
            vars.remaining_lusd_in_stab_pool -= single_liquidation.debt_to_offset
            totals = self._add_liquidation_values_to_totals(totals, single_liquidation)
        else:
            continue

    return totals

@internal
def _get_totals_from_batch_liquidate_normal_mode(
    active_pool: IActivePool,
    default_pool: IDefaultPool,
    price: uint256,
    lusd_in_stab_pool: uint256,
    trove_array: DynArray[address, 1000]
) -> LiquidationTotals:
    vars: LocalVariablesLiquidationSequence = empty(LocalVariablesLiquidationSequence)
    single_liquidation: LiquidationValues = empty(LiquidationValues)
    totals: LiquidationTotals = empty(LiquidationTotals)

    vars.remaining_lusd_in_stab_pool = lusd_in_stab_pool
    for i: uint256 in range(len(trove_array), bound=base.MAX_TROVES):
        vars.user = trove_array[vars.i]
        vars.icr = self._get_current_icr(vars.user, price)

        if vars.icr < base.MCR:
            single_liquidation = self._liquidate_normal_mode(
                active_pool, default_pool, vars.user, vars.remaining_lusd_in_stab_pool
            )
            vars.remaining_lusd_in_stab_pool -= single_liquidation.debt_to_offset
            totals = self._add_liquidation_values_to_totals(totals, single_liquidation)
    return totals

@internal
@pure
def _add_liquidation_values_to_totals(
    old_totals: LiquidationTotals,
    single_liquidation: LiquidationValues
) -> LiquidationTotals:
    new_totals: LiquidationTotals = empty(LiquidationTotals)

    new_totals.total_coll_gas_compensation = old_totals.total_coll_gas_compensation + single_liquidation.coll_gas_compensation
    new_totals.total_lusd_gas_compensation = old_totals.total_lusd_gas_compensation + single_liquidation.lusd_gas_compensation
    new_totals.total_debt_in_sequence = old_totals.total_debt_in_sequence + single_liquidation.entire_trove_debt
    new_totals.total_coll_in_sequence = old_totals.total_coll_in_sequence + single_liquidation.entire_trove_coll
    new_totals.total_debt_to_offset = old_totals.total_debt_to_offset + single_liquidation.debt_to_offset
    new_totals.total_coll_to_send_to_sp = old_totals.total_coll_to_send_to_sp + single_liquidation.coll_to_send_to_sp
    new_totals.total_debt_to_redistribute = old_totals.total_debt_to_redistribute + single_liquidation.debt_to_redistribute
    new_totals.total_coll_to_redistribute = old_totals.total_coll_to_redistribute + single_liquidation.coll_to_redistribute
    new_totals.total_coll_surplus = old_totals.total_coll_surplus + single_liquidation.coll_surplus

    return new_totals

@internal
def _send_gas_compensation(active_pool: IActivePool, liquidator: address, rd: uint256, eth: uint256):
    if rd > 0:
        extcall self.lusd_token.return_from_pool(self.gas_pool_address, liquidator, rd)
    if eth > 0:
        extcall active_pool.send_eth(liquidator, eth)

@internal
def _move_pending_trove_rewards_to_active_pool(active_pool: IActivePool, default_pool: IDefaultPool, rd: uint256, eth: uint256):
    extcall IPool(default_pool.address).decrease_lusd_debt(rd)
    extcall IPool(active_pool.address).increase_lusd_debt(rd)
    if eth > 0:
        extcall default_pool.send_eth_to_active_pool(eth)

@internal
def _redeem_collateral_from_trove(
    contracts_cache: ContractsCache,
    borrower: address,
    max_lusd_amount: uint256,
    price: uint256,
    upper_partial_redemption_hint: address,
    lower_partial_redemption_hint: address,
    partial_redemption_hint_nicr: uint256
) -> SingleRedemptionValues:
    single_redemption: SingleRedemptionValues = empty(SingleRedemptionValues)

    single_redemption.lusd_lot = min(max_lusd_amount, self.troves[borrower].debt - base.RD_GAS_COMPENSATION)
    single_redemption.eth_lot = (single_redemption.lusd_lot * base.DECIMAL_PRECISION) // price

    new_debt : uint256 = self.troves[borrower].debt - single_redemption.lusd_lot
    new_coll : uint256 = self.troves[borrower].coll - single_redemption.eth_lot

    if new_debt == base.RD_GAS_COMPENSATION:
        self._remove_stake(borrower)
        self._close_trove(borrower, Status.CLOSED_BY_REDEMPTION)
        self._redeem_close_trove(contracts_cache, borrower, base.RD_GAS_COMPENSATION, new_coll)
        log TroveUpdated(borrower, 0, 0, 0, TroveManagerOperation.REDEEM_COLLATERAL)
    else:
        new_nicr : uint256 = math._compute_nominal_cr(new_coll, new_debt)
        if new_nicr != partial_redemption_hint_nicr or base._get_net_debt(new_debt) < base.MIN_NET_DEBT:
            single_redemption.cancelled_partial = True
            return single_redemption

        extcall contracts_cache.sorted_troves.re_insert(borrower, new_nicr, upper_partial_redemption_hint, lower_partial_redemption_hint)

        self.troves[borrower].debt = new_debt
        self.troves[borrower].coll = new_coll
        self._update_stake_and_total_stakes(borrower)

        log TroveUpdated(
            borrower,
            new_debt,
            new_coll,
            self.troves[borrower].stake,
            TroveManagerOperation.REDEEM_COLLATERAL
        )
    return single_redemption

@internal
def _redeem_close_trove(contracts_cache: ContractsCache, borrower: address, rd: uint256, eth: uint256):
    extcall contracts_cache.lusd_token.burn(self.gas_pool_address, rd)
    extcall contracts_cache.active_pool.decrease_lusd_debt(rd)
    extcall contracts_cache.coll_surplus_pool.account_surplus(borrower, eth)
    extcall contracts_cache.active_pool.send_eth(contracts_cache.coll_surplus_pool.address, eth)

@internal
@view
def _is_valid_first_redemption_hint(
    sorted_troves: ISortedTroves, first_redemption_hint: address, price: uint256
) -> bool:
    if first_redemption_hint == empty(address) or not staticcall sorted_troves.contains(first_redemption_hint) or self._get_current_icr(first_redemption_hint, price) < base.MCR:
        return False
    next_trove: address = staticcall sorted_troves.get_next(first_redemption_hint)
    return next_trove == empty(address) or self._get_current_icr(next_trove, price) < base.MCR

## Send RDamount RD to the system and redeem the corresponding amount of collateral from as many Troves as are needed to fill the redemption
# request.  Applies pending rewards to a Trove before reducing its debt and coll.
#
# Note that if amount is very large, this function can run out of gas, specially if traversed troves are small. This can be easily avoided by
# splitting the total amount in appropriate chunks and calling the function multiple times.
#
# Param `_maxIterations` can also be provided, so the loop through Troves is capped (if it’s zero, it will be ignored).This makes it easier to
# avoid OOG for the frontend, as only knowing approximately the average cost of an iteration is enough, without needing to know the “topology”
# of the trove list. It also avoids the need to set the cap in stone in the contract, nor doing gas calculations, as both gas price and opcode
# costs can vary.
#
# All Troves that are redeemed from -- with the likely exception of the last one -- will end up with no debt left, therefore they will be closed.
# If the last Trove does have some remaining debt, it has a finite ICR, and the reinsertion could be anywhere in the list, therefore it requires a hint.
# A frontend should use getRedemptionHints() to calculate what the ICR of this Trove will be after redemption, and pass a hint for its position
# in the sortedTroves list along with the ICR value that the hint was found for.
#
# If another transaction modifies the list between calling getRedemptionHints() and passing the hints to redeemCollateral(), it
# is very likely that the last (partially) redeemed Trove would end up with a different ICR than what the hint is for. In this case the
# redemption will stop after the last completely redeemed Trove and the sender will keep the remaining RD amount, which they can attempt
# to redeem later.
##

@external
def redeem_collateral(
    lusd_amount: uint256,
    first_redemption_hint: address,
    upper_partial_redemption_hint: address,
    lower_partial_redemption_hint: address,
    partial_redemption_hint_nicr: uint256,
    max_iterations: uint256,
    max_fee_percentage: uint256
):
    contracts_cache: ContractsCache = ContractsCache(
        active_pool=self.active_pool,
        default_pool=self.default_pool,
        lusd_token=self.lusd_token,
        gov_staking=self.gov_staking,
        sorted_troves=self.sorted_troves,
        coll_surplus_pool=self.coll_surplus_pool,
        gas_pool_address=self.gas_pool_address
    )
    totals: RedemptionTotals = empty(RedemptionTotals)

    self._require_valid_max_fee_percentage(max_fee_percentage)
    self._require_after_bootstrap_period()
    totals.price = extcall self.price_feed.fetch_price()
    self._require_tcr_over_mcr(totals.price)
    self._require_amount_greater_than_zero(lusd_amount)
    self._require_lusd_balance_covers_redemption(contracts_cache.lusd_token, msg.sender, lusd_amount)

    totals.total_lusd_supply_at_start = self._get_entire_system_debt()
    assert staticcall contracts_cache.lusd_token.balanceOf(msg.sender) <= totals.total_lusd_supply_at_start

    totals.remaining_rd = lusd_amount
    current_borrower: address = empty(address)
    if self._is_valid_first_redemption_hint(contracts_cache.sorted_troves, first_redemption_hint, totals.price):
        current_borrower = first_redemption_hint
    else:
        current_borrower = staticcall contracts_cache.sorted_troves.get_last()

        for _: uint256 in range(staticcall contracts_cache.sorted_troves.get_size(), bound=base.MAX_TROVES):
            if current_borrower == empty(address) or self._get_current_icr(current_borrower, totals.price) >= base.MCR:
                break
            current_borrower = staticcall contracts_cache.sorted_troves.get_prev(current_borrower)

    n_iterations: uint256 = 0
    if max_iterations == 0:
        n_iterations = max_value(uint256)
    else:
        n_iterations = max_iterations

    for _: uint256 in range(n_iterations, bound=max_value(uint256)):
        if current_borrower == empty(address) or totals.remaining_rd == 0:
            break

        # Save the address of the Trove preceding the current one before modifying the list
        next_user_to_check: address = staticcall contracts_cache.sorted_troves.get_prev(current_borrower)

        self._apply_pending_rewards(
            contracts_cache.active_pool, 
            contracts_cache.default_pool, 
            current_borrower
        )

        single_redemption: SingleRedemptionValues = self._redeem_collateral_from_trove(
            contracts_cache,
            current_borrower,
            totals.remaining_rd,
            totals.price,
            upper_partial_redemption_hint,
            lower_partial_redemption_hint,
            partial_redemption_hint_nicr
        )

        if single_redemption.cancelled_partial:
            break  # Partial redemption was cancelled, stop processing

        totals.total_lusd_to_redeem += single_redemption.lusd_lot
        totals.total_eth_drawn += single_redemption.eth_lot

        totals.remaining_rd -= single_redemption.lusd_lot
        current_borrower = next_user_to_check

    assert totals.total_eth_drawn > 0, "TroveManager: Unable to redeem any amount"
    self._update_base_rate_from_redemption(totals.total_eth_drawn, totals.price, totals.total_lusd_supply_at_start)
    totals.eth_fee = self._get_redemption_fee(totals.total_eth_drawn)
    base._require_user_accepts_fee(totals.eth_fee, totals.total_eth_drawn, max_fee_percentage)

    extcall contracts_cache.active_pool.send_eth(contracts_cache.gov_staking.address, totals.eth_fee)
    extcall contracts_cache.gov_staking.increase_f_eth(totals.eth_fee)
    totals.eth_to_send_to_redeemer = totals.total_eth_drawn - totals.eth_fee

    log Redemption(lusd_amount, totals.total_lusd_to_redeem, totals.total_eth_drawn, totals.eth_fee)

    extcall contracts_cache.lusd_token.burn(msg.sender, totals.total_lusd_to_redeem)
    extcall contracts_cache.active_pool.decrease_lusd_debt(totals.total_lusd_to_redeem)
    extcall contracts_cache.active_pool.send_eth(msg.sender, totals.eth_to_send_to_redeemer)

@external
@view
def get_nominal_icr(borrower: address) -> uint256:
    return self._get_nominal_icr(borrower)

@internal
@view
def _get_nominal_icr(borrower: address) -> uint256:
    current_eth: uint256 = 0
    current_lusd_debt: uint256 = 0
    current_eth, current_lusd_debt = self._get_current_trove_amounts(borrower)
    return math._compute_nominal_cr(current_eth, current_lusd_debt)

@external
@view
def get_current_icr(borrower: address, price: uint256) -> uint256:
    return self._get_current_icr(borrower, price)

@internal
@view
def _get_current_icr(borrower: address, price: uint256) -> uint256:
    current_eth: uint256 = 0
    current_lusd_debt: uint256 = 0
    current_eth, current_lusd_debt = self._get_current_trove_amounts(borrower)
    return math._compute_cr(current_eth, current_lusd_debt, price)

@internal
@view
def _get_current_trove_amounts(borrower: address) -> (uint256, uint256):
    pending_eth_reward: uint256 = self._get_pending_eth_reward(borrower)
    pending_lusd_debt_reward: uint256 = self._get_pending_lusd_debt_reward(borrower)
    current_eth: uint256 = self.troves[borrower].coll + pending_eth_reward
    current_lusd_debt: uint256 = self.troves[borrower].debt + pending_lusd_debt_reward
    return current_eth, current_lusd_debt

@external
def apply_pending_rewards(borrower: address):
    self._require_caller_is_borrower_operations()
    self._apply_pending_rewards(self.active_pool, self.default_pool, borrower)

@internal
def _apply_pending_rewards(active_pool: IActivePool, default_pool: IDefaultPool, borrower: address):
    if self._has_pending_rewards(borrower):
        self._require_trove_is_active(borrower)
        pending_eth_reward: uint256 = self._get_pending_eth_reward(borrower)
        pending_lusd_debt_reward: uint256 = self._get_pending_lusd_debt_reward(borrower)
        self.troves[borrower].coll += pending_eth_reward
        self.troves[borrower].debt += pending_lusd_debt_reward
        self._update_trove_reward_snapshots(borrower)
        self._move_pending_trove_rewards_to_active_pool(active_pool, default_pool, pending_lusd_debt_reward, pending_eth_reward)
        log TroveUpdated(
            borrower,
            self.troves[borrower].debt,
            self.troves[borrower].coll,
            self.troves[borrower].stake,
            TroveManagerOperation.APPLY_PENDING_REWARDS
        )

@external
def update_trove_reward_snapshots(borrower: address):
    self._require_caller_is_borrower_operations()
    self._update_trove_reward_snapshots(borrower)

@internal
def _update_trove_reward_snapshots(borrower: address):
    self.reward_snapshots[borrower].eth = self.l_eth
    self.reward_snapshots[borrower].lusd_debt = self.l_lusd_debt
    log TroveSnapshotsUpdated(self.l_eth, self.l_lusd_debt)

@external
@view
def get_pending_eth_reward(borrower: address) -> uint256:
    return self._get_pending_eth_reward(borrower)

@internal
@view
def _get_pending_eth_reward(borrower: address) -> uint256:
    snapshot_eth: uint256 = self.reward_snapshots[borrower].eth
    reward_per_unit_staked: uint256 = self.l_eth - snapshot_eth
    if reward_per_unit_staked == 0 or self.troves[borrower].status != Status.ACTIVE:
        return 0
    stake: uint256 = self.troves[borrower].stake
    return (stake * reward_per_unit_staked) // base.DECIMAL_PRECISION

@external
@view
def get_pending_lusd_debt_reward(borrower: address) -> uint256:
    return self._get_pending_lusd_debt_reward(borrower)

@internal
@view
def _get_pending_lusd_debt_reward(borrower: address) -> uint256:
    snapshot_lusd_debt: uint256 = self.reward_snapshots[borrower].lusd_debt
    reward_per_unit_staked: uint256 = self.l_lusd_debt - snapshot_lusd_debt
    if reward_per_unit_staked == 0 or self.troves[borrower].status != Status.ACTIVE:
        return 0
    stake: uint256 = self.troves[borrower].stake
    return (stake * reward_per_unit_staked) // base.DECIMAL_PRECISION

@external
@view
def has_pending_rewards(borrower: address) -> bool:
    return self._has_pending_rewards(borrower)

@internal
@view
def _has_pending_rewards(borrower: address) -> bool:
    if self.troves[borrower].status != Status.ACTIVE:
        return False
    return self.reward_snapshots[borrower].eth < self.l_eth

@external
@view
def get_entire_debt_and_coll(borrower: address) -> (uint256, uint256, uint256, uint256):
    return self._get_entire_debt_and_coll(borrower)

@internal
@view
def _get_entire_debt_and_coll(borrower: address) -> (uint256, uint256, uint256, uint256):
    debt: uint256 = self.troves[borrower].debt
    coll: uint256 = self.troves[borrower].coll
    pending_lusd_debt_reward: uint256 = self._get_pending_lusd_debt_reward(borrower)
    pending_eth_reward: uint256 = self._get_pending_eth_reward(borrower)
    debt += pending_lusd_debt_reward
    coll += pending_eth_reward
    return debt, coll, pending_lusd_debt_reward, pending_eth_reward

@external
def remove_stake(borrower: address):
    self._require_caller_is_borrower_operations()
    self._remove_stake(borrower)

@internal
def _remove_stake(borrower: address):
    stake: uint256 = self.troves[borrower].stake
    self.total_stakes -= stake
    self.troves[borrower].stake = 0

@external
def update_stake_and_total_stakes(borrower: address) -> uint256:
    self._require_caller_is_borrower_operations()
    return self._update_stake_and_total_stakes(borrower)

@internal
def _update_stake_and_total_stakes(borrower: address) -> uint256:
    new_stake: uint256 = self._compute_new_stake(self.troves[borrower].coll)
    old_stake: uint256 = self.troves[borrower].stake
    self.troves[borrower].stake = new_stake
    self.total_stakes = self.total_stakes - old_stake + new_stake
    log TotalStakesUpdated(self.total_stakes)
    return new_stake

@internal
@view
def _compute_new_stake(coll: uint256) -> uint256:
    if self.total_collateral_snapshot == 0:
        return coll
    assert self.total_stakes_snapshot > 0
    return (coll * self.total_stakes_snapshot) // self.total_collateral_snapshot

@internal
def _redistribute_debt_and_coll(active_pool: IActivePool, default_pool: IDefaultPool, debt: uint256, coll: uint256):
    if debt == 0:
        return

    eth_numerator: uint256 = (coll * base.DECIMAL_PRECISION) + self.last_eth_error_redistribution
    lusd_debt_numerator: uint256 = (debt * base.DECIMAL_PRECISION) + self.last_lusd_debt_error_redistribution

    eth_reward_per_unit_staked: uint256 = eth_numerator // self.total_stakes
    lusd_debt_reward_per_unit_staked: uint256 = lusd_debt_numerator // self.total_stakes

    self.last_eth_error_redistribution = eth_numerator - (eth_reward_per_unit_staked * self.total_stakes)
    self.last_lusd_debt_error_redistribution = lusd_debt_numerator - (lusd_debt_reward_per_unit_staked * self.total_stakes)

    self.l_eth += eth_reward_per_unit_staked
    self.l_lusd_debt += lusd_debt_reward_per_unit_staked

    log LTermsUpdated(self.l_eth, self.l_lusd_debt)

    extcall IPool(active_pool.address).decrease_lusd_debt(debt)
    extcall IPool(default_pool.address).increase_lusd_debt(debt)
    extcall active_pool.send_eth(default_pool.address, coll)

@external
def close_trove(borrower: address):
    self._require_caller_is_borrower_operations()
    self._close_trove(borrower, Status.CLOSED_BY_OWNER)

@internal
def _close_trove(borrower: address, closed_status: Status):
    assert closed_status != Status.NON_EXISTENT and closed_status != Status.ACTIVE
    trove_owners_array_length: uint256 = len(self.trove_owners)
    self._require_more_than_one_trove_in_system(trove_owners_array_length)

    self.troves[borrower].status = closed_status
    self.troves[borrower].coll = 0
    self.troves[borrower].debt = 0

    self.reward_snapshots[borrower].eth = 0
    self.reward_snapshots[borrower].lusd_debt = 0

    self._remove_trove_owner(borrower, trove_owners_array_length)
    extcall self.sorted_troves.remove(borrower)

@internal
def _update_system_snapshots_exclude_coll_remainder(active_pool: IActivePool, coll_remainder: uint256):
    self.total_stakes_snapshot = self.total_stakes
    active_coll: uint256 = staticcall active_pool.get_eth()
    liquidated_coll: uint256 = staticcall IPool(self.default_pool.address).get_eth()
    self.total_collateral_snapshot = active_coll - coll_remainder + liquidated_coll
    log SystemSnapshotsUpdated(self.total_stakes_snapshot, self.total_collateral_snapshot)

@external
def add_trove_owner_to_array(borrower: address) -> uint128:
    self._require_caller_is_borrower_operations()
    return self._add_trove_owner_to_array(borrower)

@internal
def _add_trove_owner_to_array(borrower: address) -> uint128:
    self.trove_owners.append(borrower)
    index: uint128 = convert(len(self.trove_owners), uint128) - 1
    self.troves[borrower].array_index = index
    return index

@internal
def _remove_trove_owner(borrower: address, trove_owners_array_length: uint256):
    trove_status: Status = self.troves[borrower].status
    assert trove_status != Status.NON_EXISTENT and trove_status != Status.ACTIVE

    index: uint128 = self.troves[borrower].array_index
    length: uint256 = trove_owners_array_length
    idx_last: uint256 = length - 1
    assert convert(index, uint256) <= idx_last

    address_to_move: address = self.trove_owners[idx_last]
    self.trove_owners[index] = address_to_move
    self.troves[address_to_move].array_index = index
    log TroveIndexUpdated(address_to_move, index)
    self.trove_owners.pop()

@external
@view
def get_tcr(price: uint256) -> uint256:
    return self._get_tcr(price)

@external
@view
def check_recovery_mode(price: uint256) -> bool:
    return self._check_recovery_mode(price)

@internal
@pure
def _check_potential_recovery_mode(
    entire_system_coll: uint256,
    entire_system_debt: uint256,
    price: uint256
) -> bool:
    tcr: uint256 = math._compute_cr(entire_system_coll, entire_system_debt, price)
    return tcr < base.CCR

@internal
def _update_base_rate_from_redemption(eth_drawn: uint256, price: uint256, total_lusd_supply: uint256) -> uint256:
    decayed_base_rate: uint256 = self._calc_decayed_base_rate()
    redeemed_lusd_fraction: uint256 = (eth_drawn * price) // total_lusd_supply
    new_base_rate: uint256 = decayed_base_rate + (redeemed_lusd_fraction // BETA)
    new_base_rate = min(new_base_rate, base.DECIMAL_PRECISION)
    assert new_base_rate > 0
    self.base_rate = new_base_rate
    log BaseRateUpdated(new_base_rate)
    self._update_last_fee_op_time()
    return new_base_rate

@external
def get_redemption_rate() -> uint256:
    return self._calc_redemption_rate(self.base_rate)

@internal
def _get_redemption_rate() -> uint256:
    return self._calc_redemption_rate(self.base_rate)

@external
def get_redemption_rate_with_decay() -> uint256:
    return self._get_redemption_rate_with_decay()

@internal
@view
def _get_redemption_rate_with_decay() -> uint256:
    return self._calc_redemption_rate(self._calc_decayed_base_rate())

@internal
@pure
def _calc_redemption_rate(base_rate: uint256) -> uint256:
    return min(REDEMPTION_FEE_FLOOR + base_rate, base.DECIMAL_PRECISION)

@internal
def _get_redemption_fee(eth_drawn: uint256) -> uint256:
    return self._calc_redemption_fee(self._get_redemption_rate(), eth_drawn)

@external
@view
def get_redemption_fee_with_decay(eth_drawn: uint256) -> uint256:
    return self._calc_redemption_fee(self._get_redemption_rate_with_decay(), eth_drawn)

@internal
@pure
def _calc_redemption_fee(redemption_rate: uint256, eth_drawn: uint256) -> uint256:
    redemption_fee: uint256 = (redemption_rate * eth_drawn) // base.DECIMAL_PRECISION
    assert redemption_fee < eth_drawn, "TroveManager: Fee would eat up all returned collateral"
    return redemption_fee

@external
@view
def get_borrowing_rate() -> uint256:
    return self._get_borrowing_rate()

@internal
@view
def _get_borrowing_rate() -> uint256:
    return self._calc_borrowing_rate(self.base_rate)

@external
@view
def get_borrowing_rate_with_decay() -> uint256:
     return self._get_borrowing_rate_with_decay()

@internal
@view
def _get_borrowing_rate_with_decay() -> uint256:
    return self._calc_borrowing_rate(self._calc_decayed_base_rate())

@internal
@pure
def _calc_borrowing_rate(base_rate: uint256) -> uint256:
    return min(
        base.BORROWING_FEE_FLOOR + base_rate,
        MAX_BORROWING_FEE
    )

@external
@view
def get_borrowing_fee(lusd_debt: uint256) -> uint256:
    return self._calc_borrowing_fee(self._get_borrowing_rate(), lusd_debt)

@external
@view
def get_borrowing_fee_with_decay(lusd_debt: uint256) -> uint256:
    return self._calc_borrowing_fee(self._get_borrowing_rate_with_decay(), lusd_debt)

@internal
@pure
def _calc_borrowing_fee(borrowing_rate: uint256, lusd_debt: uint256) -> uint256:
    return (borrowing_rate * lusd_debt) // base.DECIMAL_PRECISION

@external
def decay_base_rate_from_borrowing():
    self._require_caller_is_borrower_operations()
    decayed_base_rate: uint256 = self._calc_decayed_base_rate()
    assert decayed_base_rate <= base.DECIMAL_PRECISION
    self.base_rate = decayed_base_rate
    log BaseRateUpdated(decayed_base_rate)
    self._update_last_fee_op_time()

@internal
def _update_last_fee_op_time():
    time_passed: uint256 = block.timestamp - self.last_fee_operation_time
    if time_passed >= SECONDS_IN_ONE_MINUTE:
        self.last_fee_operation_time = block.timestamp
        log LastFeeOpTimeUpdated(block.timestamp)

@internal
@view
def _calc_decayed_base_rate() -> uint256:
    minutes_passed: uint256 = self._minutes_passed_since_last_fee_op()
    decay_factor: uint256 = math._dec_pow(MINUTE_DECAY_FACTOR, minutes_passed)
    return (self.base_rate * decay_factor) // base.DECIMAL_PRECISION

@internal
@view
def _minutes_passed_since_last_fee_op() -> uint256:
    return (block.timestamp - self.last_fee_operation_time) // SECONDS_IN_ONE_MINUTE

@internal
@view
def _require_caller_is_borrower_operations():
    assert msg.sender == self.borrower_operations_address, "TroveManager: Caller is not the BorrowerOperations contract"

@internal
@view
def _require_trove_is_active(borrower: address):
    assert self.troves[borrower].status == Status.ACTIVE, "TroveManager: Trove does not exist or is closed"

@internal
@view
def _require_lusd_balance_covers_redemption(lusd_token: ILUSDToken, redeemer: address, amount: uint256):
    assert staticcall lusd_token.balanceOf(redeemer) >= amount, "TroveManager: Requested redemption amount must be <= user's RD token balance"

@internal
@view
def _require_more_than_one_trove_in_system(trove_owners_array_length: uint256):
    assert trove_owners_array_length > 1 and staticcall self.sorted_troves.get_size() > 1, "TroveManager: Only one trove in the system"

@internal
@pure
def _require_amount_greater_than_zero(amount: uint256):
    assert amount > 0, "TroveManager: Amount must be greater than zero"

@internal
@view
def _require_tcr_over_mcr(price: uint256):
    assert self._get_tcr(price) >= base.MCR, "TroveManager: Cannot redeem when TCR < base.MCR"

@internal
@view
def _require_after_bootstrap_period():
    system_deployment_time: uint256 = staticcall self.gov_token.get_deployment_start_time()
    assert block.timestamp >= system_deployment_time + BOOTSTRAP_PERIOD, "TroveManager: Redemptions are not allowed during bootstrap phase"

@internal
@view
def _require_valid_max_fee_percentage(max_fee_percentage: uint256):
    assert max_fee_percentage >= REDEMPTION_FEE_FLOOR and max_fee_percentage <= base.DECIMAL_PRECISION, "Max fee percentage must be between 0.5% and 100%"

@external
@view
def get_trove_status(borrower: address) -> Status:
    return self.troves[borrower].status

@external
@view
def get_trove_stake(borrower: address) -> uint256:
    return self.troves[borrower].stake

@external
@view
def get_trove_debt(borrower: address) -> uint256:
    return self.troves[borrower].debt

@external
@view
def get_trove_coll(borrower: address) -> uint256:
    return self.troves[borrower].coll

@external
def set_trove_status(borrower: address, num: Status):
    self._require_caller_is_borrower_operations()
    self.troves[borrower].status = num

@external
def increase_trove_coll(borrower: address, coll_increase: uint256) -> uint256:
    self._require_caller_is_borrower_operations()
    new_coll: uint256 = self.troves[borrower].coll + coll_increase
    self.troves[borrower].coll = new_coll
    return new_coll

@external
def decrease_trove_coll(borrower: address, coll_decrease: uint256) -> uint256:
    self._require_caller_is_borrower_operations()
    new_coll: uint256 = self.troves[borrower].coll - coll_decrease
    self.troves[borrower].coll = new_coll
    return new_coll

@external
def increase_trove_debt(borrower: address, debt_increase: uint256) -> uint256:
    self._require_caller_is_borrower_operations()
    new_debt: uint256 = self.troves[borrower].debt + debt_increase
    self.troves[borrower].debt = new_debt
    return new_debt

@external
def decrease_trove_debt(borrower: address, debt_decrease: uint256) -> uint256:
    self._require_caller_is_borrower_operations()
    new_debt: uint256 = self.troves[borrower].debt - debt_decrease
    self.troves[borrower].debt = new_debt
    return new_debt
