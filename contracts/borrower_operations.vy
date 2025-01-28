# SPDX-License-Identifier: MIT
# pragma version ~=0.4.0

from snekmate.auth import ownable
initializes: ownable

from interfaces import ITroveManager
from interfaces import ILUSDToken
from interfaces import IActivePool
from interfaces import IDefaultPool
from interfaces import IPriceFeed
from interfaces import ISortedTroves
from interfaces import ILQTYStaking
from interfaces import ICollSurplusPool

import math
import base

NAME: constant(String[18]) = "BorrowerOperations"

# --- Connected contract declarations ---

trove_manager: public(ITroveManager)
active_pool: IActivePool
default_pool: IDefaultPool
price_feed: IPriceFeed
stability_pool_address: address
gas_pool_address: address
coll_surplus_pool: ICollSurplusPool
gov_staking: public(ILQTYStaking)
gov_staking_address: public(address)
lusd_token: public(ILUSDToken)
sorted_troves: public(ISortedTroves)

# --- Variable container structs ---

struct LocalVariablesAdjustTrove:
    price: uint256
    coll_change: uint256
    net_debt_change: uint256
    is_coll_increase: bool
    debt: uint256
    coll: uint256
    old_icr: uint256
    new_icr: uint256
    new_tcr: uint256
    lusd_fee: uint256
    new_debt: uint256
    new_coll: uint256
    stake: uint256

struct LocalVariablesOpenTrove:
    price: uint256
    lusd_fee: uint256
    net_debt: uint256
    composite_debt: uint256
    icr: uint256
    nicr: uint256
    stake: uint256
    array_index: uint256

struct ContractsCache:
    trove_manager: ITroveManager
    active_pool: IActivePool
    lusd_token: ILUSDToken

flag BorrowerOperation:
    open_trove
    close_trove
    adjust_trove

# --- Events ---

event TroveManagerAddressChanged:
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

event PriceFeedAddressChanged:
    new_address: address

event SortedTrovesAddressChanged:
    new_address: address

event RDTokenAddressChanged:
    new_address: address

event LQTYStakingAddressChanged:
    new_address: address

event TroveCreated:
    borrower: address
    array_index: uint256

event TroveUpdated:
    borrower: address
    debt: uint256
    coll: uint256
    stake: uint256
    operation: BorrowerOperation

event RDBorrowingFeePaid:
    borrower: address
    lusd_fee: uint256

@deploy
def __init__():
    ownable.__init__()

@external
def set_addresses(
    trove_manager_address: address,
    active_pool_address: address,
    default_pool_address: address,
    stability_pool_address: address,
    gas_pool_address: address,
    coll_surplus_pool_address: address,
    price_feed_address: address,
    sorted_troves_address: address,
    lusd_token_address: address,
    gov_staking_address: address
):
    assert base.MIN_NET_DEBT > 0

    assert trove_manager_address.is_contract
    assert active_pool_address.is_contract
    assert default_pool_address.is_contract
    assert stability_pool_address.is_contract
    assert gas_pool_address.is_contract
    assert coll_surplus_pool_address.is_contract
    assert price_feed_address.is_contract
    assert sorted_troves_address.is_contract
    assert lusd_token_address.is_contract
    assert gov_staking_address.is_contract

    self.trove_manager = ITroveManager(trove_manager_address)
    self.active_pool = IActivePool(active_pool_address)
    self.default_pool = IDefaultPool(default_pool_address)
    self.stability_pool_address = stability_pool_address
    self.gas_pool_address = gas_pool_address
    self.coll_surplus_pool = ICollSurplusPool(coll_surplus_pool_address)
    self.price_feed = IPriceFeed(price_feed_address)
    self.sorted_troves = ISortedTroves(sorted_troves_address)
    self.lusd_token = ILUSDToken(lusd_token_address)
    self.gov_staking_address = gov_staking_address
    self.gov_staking = ILQTYStaking(gov_staking_address)

    log TroveManagerAddressChanged(trove_manager_address)
    log ActivePoolAddressChanged(active_pool_address)
    log DefaultPoolAddressChanged(default_pool_address)
    log StabilityPoolAddressChanged(stability_pool_address)
    log GasPoolAddressChanged(gas_pool_address)
    log CollSurplusPoolAddressChanged(coll_surplus_pool_address)
    log PriceFeedAddressChanged(price_feed_address)
    log SortedTrovesAddressChanged(sorted_troves_address)
    log RDTokenAddressChanged(lusd_token_address)
    log LQTYStakingAddressChanged(gov_staking_address)

    ownable._transfer_ownership(empty(address))

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
@payable
def open_trove(
    max_fee_percentage: uint256,
    lusd_amount: uint256,
    upper_hint: address,
    lower_hint: address
):
    contracts_cache: ContractsCache = ContractsCache(trove_manager=self.trove_manager,
    active_pool=self.active_pool, lusd_token=self.lusd_token)
    vars: LocalVariablesOpenTrove = LocalVariablesOpenTrove(price=0, lusd_fee=0, net_debt=0,
    composite_debt=0, icr=0, nicr=0, stake=0, array_index=0)

    vars.price = extcall self.price_feed.fetch_price()
    is_recovery_mode: bool = self._check_recovery_mode(vars.price)

    self._require_valid_max_fee_percentage(max_fee_percentage, is_recovery_mode)
    self._require_trove_is_not_active(contracts_cache.trove_manager, msg.sender)

    vars.lusd_fee = 0
    vars.net_debt = lusd_amount

    if not is_recovery_mode:
        vars.lusd_fee = self._trigger_borrowing_fee(contracts_cache.trove_manager, contracts_cache.lusd_token, lusd_amount, max_fee_percentage)
        vars.net_debt += vars.lusd_fee

    self._require_at_least_min_net_debt(vars.net_debt)
    vars.composite_debt = self._get_composite_debt(vars.net_debt)
    assert vars.composite_debt > 0

    vars.icr = math._compute_cr(msg.value, vars.composite_debt, vars.price)
    vars.nicr = math._compute_nominal_cr(msg.value, vars.composite_debt)

    if is_recovery_mode:
        self._require_icr_is_above_ccr(vars.icr)
    else:
        self._require_icr_is_above_mcr(vars.icr)
        new_tcr : uint256 = self._get_new_tcr_from_trove_change(msg.value, True, vars.composite_debt, True, vars.price)
        self._require_new_tcr_is_above_ccr(new_tcr)

    extcall contracts_cache.trove_manager.set_trove_status(msg.sender, 2)
    extcall contracts_cache.trove_manager.increase_trove_coll(msg.sender, msg.value)
    extcall contracts_cache.trove_manager.increase_trove_debt(msg.sender, vars.composite_debt)
    extcall contracts_cache.trove_manager.update_trove_reward_snapshots(msg.sender)
    vars.stake = extcall contracts_cache.trove_manager.update_stake_and_total_stakes(msg.sender)

    extcall self.sorted_troves.insert(msg.sender, vars.nicr, upper_hint, lower_hint)
    vars.array_index = extcall contracts_cache.trove_manager.add_trove_owner_to_array(msg.sender)
    log TroveCreated(msg.sender, vars.array_index)

    self._active_pool_add_coll(contracts_cache.active_pool, msg.value)
    self._withdraw_rd(contracts_cache.active_pool, contracts_cache.lusd_token, msg.sender, lusd_amount, vars.net_debt)
    self._withdraw_rd(contracts_cache.active_pool, contracts_cache.lusd_token, self.gas_pool_address, base.RD_GAS_COMPENSATION, base.RD_GAS_COMPENSATION)

    log TroveUpdated(msg.sender, vars.composite_debt, msg.value,
                     vars.stake, BorrowerOperation.open_trove)
    log RDBorrowingFeePaid(msg.sender, vars.lusd_fee)

@external
@payable
def add_coll(upper_hint: address, lower_hint: address):
    self._adjust_trove(msg.sender, 0, 0, False, upper_hint, lower_hint, 0)

@external
@payable
def move_eth_gain_to_trove(borrower: address, upper_hint: address, lower_hint: address):
    self._require_caller_is_stability_pool()
    self._adjust_trove(borrower, 0, 0, False, upper_hint, lower_hint, 0)

@external
def withdraw_coll(coll_withdrawal: uint256, upper_hint: address, lower_hint: address):
    self._adjust_trove(msg.sender, coll_withdrawal, 0, False, upper_hint, lower_hint, 0)

@external
def withdraw_rd(max_fee_percentage: uint256, lusd_amount: uint256, upper_hint: address, lower_hint: address):
    self._adjust_trove(msg.sender, 0, lusd_amount, True, upper_hint, lower_hint, max_fee_percentage)

@external
def repay_rd(lusd_amount: uint256, upper_hint: address, lower_hint: address):
    self._adjust_trove(msg.sender, 0, lusd_amount, False, upper_hint, lower_hint, 0)

@external
@payable
def adjust_trove(max_fee_percentage: uint256, coll_withdrawal: uint256, lusd_change: uint256, is_debt_increase: bool, upper_hint: address, lower_hint: address):
    self._adjust_trove(msg.sender, coll_withdrawal, lusd_change, is_debt_increase, upper_hint, lower_hint, max_fee_percentage)

@internal
@payable
def _adjust_trove(borrower: address, coll_withdrawal: uint256, lusd_change: uint256, is_debt_increase: bool, upper_hint: address, lower_hint: address, max_fee_percentage: uint256):
    contracts_cache: ContractsCache = ContractsCache(trove_manager=self.trove_manager,
                                                     active_pool=self.active_pool,
                                                     lusd_token=self.lusd_token)

    vars: LocalVariablesAdjustTrove = LocalVariablesAdjustTrove(price=0, coll_change=0, net_debt_change=0,
    is_coll_increase=False, debt=0, coll=0, old_icr=0, new_icr=0, new_tcr=0, lusd_fee=0, new_debt=0,
    new_coll=0, stake=0)


    vars.price = extcall self.price_feed.fetch_price()
    is_recovery_mode : bool = self._check_recovery_mode(vars.price)

    if is_debt_increase:
        self._require_valid_max_fee_percentage(max_fee_percentage, is_recovery_mode)
        self._require_non_zero_debt_change(lusd_change)
    self._require_singular_coll_change(coll_withdrawal)
    self._require_non_zero_adjustment(coll_withdrawal, lusd_change)
    self._require_trove_is_active(contracts_cache.trove_manager, borrower)

    extcall contracts_cache.trove_manager.apply_pending_rewards(borrower)
     
    vars.coll_change, vars.is_coll_increase = self._get_coll_change(msg.value, coll_withdrawal)

    vars.net_debt_change = lusd_change

    if is_debt_increase and not is_recovery_mode:
        vars.lusd_fee = self._trigger_borrowing_fee(contracts_cache.trove_manager, contracts_cache.lusd_token, lusd_change, max_fee_percentage)
        vars.net_debt_change += vars.lusd_fee

    vars.debt = staticcall contracts_cache.trove_manager.get_trove_debt(borrower)
    vars.coll = staticcall contracts_cache.trove_manager.get_trove_coll(borrower)

    vars.old_icr = math._compute_cr(vars.coll, vars.debt, vars.price)
    vars.new_icr = self._get_new_icr_from_trove_change(vars.coll, vars.debt, vars.coll_change, vars.is_coll_increase, vars.net_debt_change, is_debt_increase, vars.price)

    self._require_valid_adjustment_in_current_mode(is_recovery_mode, coll_withdrawal, is_debt_increase, vars)

    if not is_debt_increase and lusd_change > 0:
        self._require_at_least_min_net_debt(base._get_net_debt(vars.debt) - vars.net_debt_change)
        self._require_valid_lusd_repayment(vars.debt, vars.net_debt_change)
        self._require_sufficient_lusd_balance(contracts_cache.lusd_token, borrower, vars.net_debt_change)

    vars.new_coll, vars.new_debt = self._update_trove_from_adjustment(contracts_cache.trove_manager, borrower, vars.coll_change, vars.is_coll_increase, vars.net_debt_change, is_debt_increase)
    vars.stake = extcall contracts_cache.trove_manager.update_stake_and_total_stakes(borrower)

    new_nicr: uint256 = self._get_new_nominal_icr_from_trove_change(vars.coll, vars.debt, vars.coll_change, vars.is_coll_increase, vars.net_debt_change, is_debt_increase)
    extcall self.sorted_troves.re_insert(borrower, new_nicr, upper_hint, lower_hint)

    self._move_tokens_and_eth_from_adjustment(contracts_cache.active_pool, contracts_cache.lusd_token, msg.sender, vars.coll_change, vars.is_coll_increase, lusd_change, is_debt_increase, vars.net_debt_change)

@external
def close_trove():
    trove_manager_cached: ITroveManager = self.trove_manager
    active_pool_cached: IActivePool = self.active_pool
    lusd_token_cached: ILUSDToken = self.lusd_token

    self._require_trove_is_active(trove_manager_cached, msg.sender)
    price: uint256 = extcall self.price_feed.fetch_price()
    self._require_not_in_recovery_mode(price)

    extcall trove_manager_cached.apply_pending_rewards(msg.sender)

    coll: uint256 = staticcall trove_manager_cached.get_trove_coll(msg.sender)
    debt: uint256 = staticcall trove_manager_cached.get_trove_debt(msg.sender)

    self._require_sufficient_lusd_balance(lusd_token_cached, msg.sender, debt - base.RD_GAS_COMPENSATION)

    new_tcr: uint256 = self._get_new_tcr_from_trove_change(coll, False, debt, False, price)
    self._require_new_tcr_is_above_ccr(new_tcr)

    extcall trove_manager_cached.remove_stake(msg.sender)
    extcall trove_manager_cached.close_trove(msg.sender)

    log TroveUpdated(msg.sender, 0, 0, 0, BorrowerOperation.close_trove) 

    self._repay_rd(active_pool_cached, lusd_token_cached, msg.sender, debt - base.RD_GAS_COMPENSATION)
    self._repay_rd(active_pool_cached, lusd_token_cached, self.gas_pool_address, base.RD_GAS_COMPENSATION)

    extcall active_pool_cached.send_eth(msg.sender, coll)

@external
def claim_collateral():
    extcall self.coll_surplus_pool.claim_coll(msg.sender)

@internal
def _trigger_borrowing_fee(trove_manager: ITroveManager, lusd_token: ILUSDToken, lusd_amount: uint256, max_fee_percentage: uint256) -> uint256:
    # Decay the baseRate state variable
    extcall trove_manager.decay_base_rate_from_borrowing()
    
    lusd_fee: uint256 = staticcall trove_manager.get_borrowing_fee(lusd_amount)

    base._require_user_accepts_fee(lusd_fee, lusd_amount, max_fee_percentage)
    
    # Send fee to LQTY staking contract
    extcall self.gov_staking.increase_f_rd(lusd_fee)
    extcall lusd_token.mint(self.gov_staking_address, lusd_fee)

    return lusd_fee

@internal
@pure
def _get_usd_value(coll: uint256, price: uint256) -> uint256:
    return (price * coll) // base.DECIMAL_PRECISION

@internal
@pure
def _get_coll_change(coll_received: uint256, requested_coll_withdrawal: uint256) -> (uint256, bool):
    if coll_received != 0:
        return coll_received, True
    else:
        return requested_coll_withdrawal, False

@internal
def _update_trove_from_adjustment(
    trove_manager: ITroveManager,
    borrower: address,
    coll_change: uint256,
    is_coll_increase: bool,
    debt_change: uint256,
    is_debt_increase: bool
) -> (uint256, uint256):
    #Update trove's collateral and debt based on whether they increase or decrease.
    new_coll: uint256 = 0
    new_debt: uint256 = 0

    if is_coll_increase:
        new_coll = extcall trove_manager.increase_trove_coll(borrower, coll_change)
    else:
        new_coll = extcall trove_manager.decrease_trove_coll(borrower, coll_change)

    if is_debt_increase:
        new_debt = extcall trove_manager.increase_trove_debt(borrower, debt_change)
    else:
        new_debt = extcall trove_manager.decrease_trove_debt(borrower, debt_change)

    return new_coll, new_debt

@internal
def _move_tokens_and_eth_from_adjustment(
    active_pool: IActivePool,
    lusd_token: ILUSDToken,
    borrower: address,
    coll_change: uint256,
    is_coll_increase: bool,
    lusd_change: uint256,
    is_debt_increase: bool,
    net_debt_change: uint256
):
    """
    Move tokens and ETH based on collateral and debt changes.
    """
    if is_debt_increase:
        self._withdraw_rd(active_pool, lusd_token, borrower, lusd_change, net_debt_change)
    else:
        self._repay_rd(active_pool, lusd_token, borrower, lusd_change)

    if is_coll_increase:
        self._active_pool_add_coll(active_pool, coll_change)
    else:
        extcall active_pool.send_eth(borrower, coll_change)

@internal
def _active_pool_add_coll(active_pool: IActivePool, amount: uint256):
    """
    Send ETH to Active Pool and increase its recorded ETH balance.
    """
    raw_call(active_pool.address, b"", value=amount, revert_on_failure=True)

@internal
def _withdraw_rd(active_pool: IActivePool, lusd_token: ILUSDToken, account: address, lusd_amount: uint256, net_debt_increase: uint256):
    """
    Issue the specified amount of RD to account and increase the total active debt.
    """
    extcall active_pool.increase_lusd_debt(net_debt_increase)
    extcall lusd_token.mint(account, lusd_amount)

@internal
def _repay_rd(active_pool: IActivePool, lusd_token: ILUSDToken, account: address, rd: uint256):
    """
    Burn the specified amount of RD from account and decrease the total active debt.
    """
    extcall active_pool.decrease_lusd_debt(rd)
    extcall lusd_token.burn(account, rd)

# --- 'Require' Wrapper Functions ---

@internal
@payable
def _require_singular_coll_change(coll_withdrawal: uint256):
    """
    Ensure that collateral is either added or withdrawn, but not both.
    """
    assert msg.value == 0 or coll_withdrawal == 0, "BorrowerOperations: Cannot withdraw and add coll"

@internal
def _require_caller_is_borrower(borrower: address):
    """
    Ensure that the caller is the borrower for a withdrawal.
    """
    assert msg.sender == borrower, "BorrowerOps: Caller must be the borrower for a withdrawal"

@internal
@payable
def _require_non_zero_adjustment(coll_withdrawal: uint256, lusd_change: uint256):
    """
    Ensure that there is at least a collateral or debt change.
    """

    assert msg.value != 0 or coll_withdrawal != 0 or lusd_change != 0, "BorrowerOps: There must be either a collateral change or a debt change"

@internal
def _require_trove_is_active(trove_manager: ITroveManager, borrower: address):
    status: uint256 = staticcall trove_manager.get_trove_status(borrower)
    assert status == 1, "BorrowerOps: Trove does not exist or is closed"

@internal
def _require_trove_is_not_active(trove_manager: ITroveManager, borrower: address):
    status: uint256 = staticcall trove_manager.get_trove_status(borrower)
    assert status != 1, "BorrowerOps: Trove is active"

@internal
def _require_non_zero_debt_change(lusd_change: uint256):
    assert lusd_change > 0, "BorrowerOps: Debt increase requires non-zero debtChange"

@internal
def _require_not_in_recovery_mode(price: uint256):
    assert not self._check_recovery_mode(price), "BorrowerOps: Operation not permitted during Recovery Mode"

@internal
def _require_no_coll_withdrawal(coll_withdrawal: uint256):
    assert coll_withdrawal == 0, "BorrowerOps: Collateral withdrawal not permitted Recovery Mode"

@internal
def _require_valid_adjustment_in_current_mode(
    is_recovery_mode: bool,
    coll_withdrawal: uint256,
    is_debt_increase: bool,
    vars: LocalVariablesAdjustTrove
):
    """
    In Recovery Mode, only allow:

    - Pure collateral top-up
    - Pure debt repayment
    - Collateral top-up with debt repayment
    - A debt increase combined with a collateral top-up which makes the ICR >= 150% and improves the ICR (and by extension improves the TCR).

    In Normal Mode, ensure:

    - The new ICR is above MCR
    - The adjustment won't pull the TCR below CCR
    """
    if is_recovery_mode:
       self._require_no_coll_withdrawal(coll_withdrawal)
       if is_debt_increase:
           self._require_icr_is_above_ccr(vars.new_icr)
           self._require_new_icr_is_above_old_icr(vars.new_icr, vars.old_icr)
    else:
        self._require_icr_is_above_mcr(vars.new_icr)
        vars.new_tcr = self._get_new_tcr_from_trove_change(
            vars.coll_change, vars.is_coll_increase, vars.net_debt_change, is_debt_increase, vars.price
        )
        self._require_new_tcr_is_above_ccr(vars.new_tcr)

@internal
@pure
def _require_icr_is_above_mcr(newICR: uint256):
    assert newICR >= base.MCR, "BorrowerOps: An operation that would result in ICR < MCR is not permitted"

@internal
@pure
def _require_icr_is_above_ccr(newICR: uint256):
    assert newICR >= base.CCR, "BorrowerOps: Operation must leave trove with ICR >= CCR"

@internal
@pure
def _require_new_icr_is_above_old_icr(newICR: uint256, oldICR: uint256):
    assert newICR >= oldICR, "BorrowerOps: Cannot decrease your Trove's ICR in Recovery Mode"

@internal
@pure
def _require_new_tcr_is_above_ccr(newTCR: uint256):
    assert newTCR >= base.CCR, "BorrowerOps: An operation that would result in TCR < CCR is not permitted"

@internal
@pure
def _require_at_least_min_net_debt(netDebt: uint256):
    assert netDebt >= base.MIN_NET_DEBT, "BorrowerOps: Trove's net debt must be greater than minimum"

@internal
@pure
def _require_valid_lusd_repayment(currentDebt: uint256, debtRepayment: uint256):
    assert debtRepayment <= currentDebt - base.RD_GAS_COMPENSATION, "BorrowerOps: Amount repaid must not be larger than the Trove's debt"

@internal
@view
def _require_caller_is_stability_pool():
    assert msg.sender == self.stability_pool_address, "BorrowerOps: Caller is not Stability Pool"

@internal
@view
def _require_sufficient_lusd_balance(lusd_token: ILUSDToken, borrower: address, debt_repayment: uint256):
    assert staticcall lusd_token.balanceOf(borrower) >= debt_repayment, "BorrowerOps: Caller doesnt have enough RD to make repayment"

# Utility functions
@internal
def _require_valid_max_fee_percentage(max_fee_percentage: uint256, is_recovery_mode: bool):
    if is_recovery_mode:
        assert max_fee_percentage <= base.DECIMAL_PRECISION, "Max fee percentage must be less than or equal to 100%"
    else:
        assert max_fee_percentage >= base.BORROWING_FEE_FLOOR and max_fee_percentage <= base.DECIMAL_PRECISION, "Max fee percentage must be between 0.5% and 100%"

# Compute the new collateral ratio, considering the change in collateral and debt
@internal
@pure
def _get_new_nominal_icr_from_trove_change(
    coll: uint256, 
    debt: uint256, 
    coll_change: uint256, 
    is_coll_increase: bool, 
    debt_change: uint256, 
    is_debt_increase: bool
) -> uint256:
    new_coll: uint256 = 0
    new_debt: uint256 = 0
    new_coll, new_debt = self._get_new_trove_amounts(coll, debt, coll_change, is_coll_increase, debt_change, is_debt_increase)
    return math._compute_nominal_cr(new_coll, new_debt)

# Compute the new collateral ratio with price
@internal
@pure
def _get_new_icr_from_trove_change(
    coll: uint256, 
    debt: uint256, 
    coll_change: uint256, 
    is_coll_increase: bool, 
    debt_change: uint256, 
    is_debt_increase: bool, 
    price: uint256
) -> uint256:
    new_coll: uint256 = 0
    new_debt: uint256 = 0
    new_coll, new_debt = self._get_new_trove_amounts(coll, debt, coll_change, is_coll_increase, debt_change, is_debt_increase)
    return math._compute_cr(new_coll, new_debt, price)

# Adjust collateral and debt amounts based on input changes
@internal
@pure
def _get_new_trove_amounts(
    coll: uint256, 
    debt: uint256, 
    coll_change: uint256, 
    is_coll_increase: bool, 
    debt_change: uint256, 
    is_debt_increase: bool
) -> (uint256, uint256):
    new_coll: uint256 = coll + coll_change if is_coll_increase else coll - coll_change
    new_debt: uint256 = debt + debt_change if is_debt_increase else debt - debt_change
    return new_coll, new_debt

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

# Calculate new Total Collateral Ratio (TCR) based on trove change
@internal
@view
def _get_new_tcr_from_trove_change(
    coll_change: uint256, 
    is_coll_increase: bool, 
    debt_change: uint256, 
    is_debt_increase: bool, 
    price: uint256
) -> uint256:
    total_coll: uint256 = self._get_entire_system_coll()
    total_debt: uint256 = self._get_entire_system_debt()

    total_coll = total_coll + coll_change if is_coll_increase else total_coll - coll_change
    total_debt = total_debt + debt_change if is_debt_increase else total_debt - debt_change

    return math._compute_cr(total_coll, total_debt, price)

@internal
@pure
def _get_composite_debt(debt: uint256) -> uint256:
    return debt + 200  # Example of additional fees (e.g., gas compensation)
