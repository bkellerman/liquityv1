# SPDX-License-Identifier: MIT
# pragma version ~=0.4.0

from interfaces import IActivePool
from interfaces import IDefaultPool
from interfaces import IPool
from interfaces import IPriceFeed

import math

DECIMAL_PRECISION: constant(uint256) = 10 ** 18

one_hundred_pct: constant(uint256) = 1000000000000000000  # 1e18 == 100%
MCR: constant(uint256) = 1100000000000000000  # 110%
CCR: constant(uint256) = 1500000000000000000  # 150%
RD_GAS_COMPENSATION: constant(uint256) = 200 * DECIMAL_PRECISION
MIN_NET_DEBT: constant(uint256) = 1800 * DECIMAL_PRECISION
PERCENT_DIVISOR: constant(uint256) = 200  # dividing by 200 yields 0.5%
BORROWING_FEE_FLOOR: constant(uint256) = DECIMAL_PRECISION // 1000 * 5  # 0.5%
MAX_TROVES: constant(uint256) = 10**6

active_pool: public(IActivePool)
default_pool: public(IDefaultPool)
price_feed: public(IPriceFeed)


@deploy
def __init__(active_pool: IActivePool, default_pool: IDefaultPool, price_feed: IPriceFeed):
    self.active_pool = active_pool
    self.default_pool = default_pool
    self.price_feed = price_feed

@internal
@pure
def _get_composite_debt(debt: uint256) -> uint256:
    return debt + RD_GAS_COMPENSATION

@internal
@pure
def _get_net_debt(debt: uint256) -> uint256:
    return debt - RD_GAS_COMPENSATION

@internal
@pure
def _get_coll_gas_compensation(entire_coll: uint256) -> uint256:
    return entire_coll // PERCENT_DIVISOR

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
@view
def _get_tcr(price: uint256) -> uint256:
    entire_system_coll: uint256 = self._get_entire_system_coll()
    entire_system_debt: uint256 = self._get_entire_system_debt()
    return math._compute_cr(entire_system_coll, entire_system_debt, price)

@internal
@view
def _check_recovery_mode(price: uint256) -> bool:
    tcr: uint256 = self._get_tcr(price)
    return tcr < CCR

@internal
@pure
def _require_user_accepts_fee(fee: uint256, amount: uint256, max_fee_percentage: uint256):
    fee_percentage: uint256 = fee * DECIMAL_PRECISION // amount
    assert fee_percentage <= max_fee_percentage, "Fee exceeded provided maximum"

