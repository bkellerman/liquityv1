# SPDX-License-Identifier: MIT
# pragma version ~=0.4.0

from snekmate.auth import ownable

from interfaces import IBorrowerOperations
from interfaces import ILUSDToken
from interfaces import ICommunityIssuance
from interfaces import IActivePool
from interfaces import IPriceFeed
from interfaces import ITroveManager
from interfaces import ISortedTroves

initializes: ownable
name: public(constant(String[13])) = "StabilityPool"
borrower_operations: public(IBorrowerOperations)
lusd_token: public(ILUSDToken)
community_issuance: public(ICommunityIssuance)
active_pool: public(IActivePool)
trove_manager: public(ITroveManager)
price_feed: public(IPriceFeed)
sorted_troves: public(ISortedTroves)

# total ether
eth: uint256
# Tracker for RD held in the pool. Changes when users deposit/withdraw, and when trove debt is offset.
total_lusd_deposits: uint256 


struct FrontEnd:
    kickbackRate: uint256
    registered: bool

struct Deposit:
    initialValue: uint256
    frontendTag: address

struct Snapshots:
    S: uint256
    P:  uint256
    G: uint256
    scale: uint128
    epoch: uint128

deposits: public(HashMap[address, Deposit])
deposit_snapshots: public(HashMap[address, Snapshots])
frontends: public(HashMap[address, FrontEnd])
frontend_stakes: public(HashMap[address, uint256])
frontend_snapshots: public(HashMap[address, Snapshots])


# Product 'P': Running product by which to multiply an initial deposit, in order to find the current compounded deposit,
# after a series of liquidations have occurred, each of which cancel some RD debt with the deposit.
#
# During its lifetime, a deposit's value evolves from d_t to d_t * P / P_t , where P_t
# is the snapshot of P taken at the instant the deposit was made. 18-digit decimal.
#

P: public(uint256)
SCALE_FACTOR: public(constant(uint256)) = 10**9

MCR: public(constant(uint256)) = 1100000000000000000

# Each time the scale of P shifts by SCALE_FACTOR, the scale is incremented by 1
current_scale: public(uint128)

# With each offset that fully empties the Pool, the epoch is incremented by 1
current_epoch: public(uint128)

# ETH Gain sum 'S': During its lifetime, each deposit d_t earns an ETH gain of ( d_t * [S - S_t] )/P_t, where S_t
# is the depositor's snapshot of S taken at the time t when the deposit was made.
#
# The 'S' sums are stored in a nested mapping (epoch => scale => sum):
#
# - The inner mapping records the sum S at different scales
# - The outer mapping records the (scale => sum) mappings, for different epochs.
#

epoch_to_scale_to_sum: public(HashMap[uint128, HashMap[uint128, uint256]])

# Similarly, the sum 'G' is used to calculate LQTY gains. During it's lifetime, each deposit d_t earns a LQTY gain of
#  ( d_t * [G - G_t] )/P_t, where G_t is the depositor's snapshot of G taken at time t when  the deposit was made.
#
#  LQTY reward events occur are triggered by depositor operations (new deposit, topup, withdrawal), and liquidations.
#  In each case, the LQTY reward is issued (i.e. G is updated), before other state changes are made.

epoch_to_scale_to_g: public(HashMap[uint128, HashMap[uint128, uint256]])

# Error tracker for the error correction in the LQTY issuance calculation
last_gov_error: public(uint256)
# Error trackers for the error correction in the offset calculation
last_eth_error_offset: public(uint256)
# Error trackers for the error correction in the offset calculation
last_lusd_loss_error_offset: public(uint256)


event StabilityPoolETHBalanceUpdated:
    new_balance: uint256

event StabilityPoolRDBalanceUpdated:
    new_balance: uint256

event BorrowerOperationsAddressChanged:
    new_address: address
event TroveManagerAddressChanged:
    new_address: address
event ActivePoolAddressChanged:
    new_address: address
event DefaultPoolAddressChanged:
    new_address: address
event LUSDTokenAddressChanged:
    new_address: address
event SortedTrovesAddressChanged:
    new_address: address
event PriceFeedAddressChanged:
    new_address: address
event CommunityIssuanceAddressChanged:
    new_address: address

event P_Updated:
    P: uint256

event S_Updated:
    S: uint256
    epoch: uint128
    scale: uint128

event G_Updated:
    G: uint256
    epoch: uint128
    scale: uint128

event EpochUpdated:
    current_epoch: uint128

event ScaleUpdated:
    current_scale: uint128

event FrontendRegistered:
    frontend: indexed(address)
    kickback_rate: uint256

event FrontendTagSet:
    depositor: indexed(address)
    frontend: indexed(address)

event DepositSnapshotUpdated:
    depositor: indexed(address)
    P: uint256
    S: uint256
    G: uint256

event FrontendSnapshotUpdated:
    frontend: indexed(address)
    P: uint256
    G: uint256

event UserDepositChanged:
    depositor: indexed(address)
    new_deposit: uint256

event FrontendStakeChanged:
    frontend: indexed(address)
    new_frontend_stake: uint256
    depositor: address

event ETHGainWithdrawn:
    depositor: indexed(address)
    eth: uint256
    lusd_loss: uint256

event LQTYPaidToDepositor:
    depositor: indexed(address)
    gov: uint256

event LQTYPaidToFrontEnd:
    frontend: indexed(address)
    gov: uint256

event EtherSent:
    to: address
    amount: uint256

@deploy
def __init__():
    ownable.__init__()
    self.P = 10**18

@external
def set_addresses(borrower_operations_address: address, trove_manager_address: address,
        active_pool_address: address, lusd_token_address: address,
        sorted_troves_address: address, price_feed_address: address,
        community_issuance_address: address):

        ownable._check_owner()

        assert borrower_operations_address.is_contract, "StabilityPool: borrower operations address is not contract"
        assert trove_manager_address.is_contract, "StabilityPool: trove manager address is not contract"
        assert active_pool_address.is_contract, "StabilityPool: active pool address is not contract"
        assert lusd_token_address.is_contract, "StabilityPool: rd token address is not contract"
        assert sorted_troves_address.is_contract, "StabilityPool: sorted troves address is not contract"
        assert price_feed_address.is_contract, "StabilityPool: price feed address is not contract"
        assert community_issuance_address.is_contract, "StabilityPool: community issuance address is not contract"


        self.borrower_operations = IBorrowerOperations(borrower_operations_address)
        self.trove_manager = ITroveManager(trove_manager_address)
        self.active_pool = IActivePool(active_pool_address)
        self.lusd_token = ILUSDToken(lusd_token_address)
        self.sorted_troves = ISortedTroves(sorted_troves_address)
        self.price_feed = IPriceFeed(price_feed_address)
        self.community_issuance = ICommunityIssuance(community_issuance_address)

        log BorrowerOperationsAddressChanged(borrower_operations_address)
        log TroveManagerAddressChanged(trove_manager_address)
        log ActivePoolAddressChanged(active_pool_address)
        log LUSDTokenAddressChanged(lusd_token_address)
        log SortedTrovesAddressChanged(sorted_troves_address)
        log PriceFeedAddressChanged(price_feed_address)
        log CommunityIssuanceAddressChanged(community_issuance_address)

# --- Getters for public variables. Required by IPool interface ---

@external
@view
def get_eth() -> uint256:
    return self.eth

@external
@view
def get_total_lusd_deposits() -> uint256:
   return self.total_lusd_deposits


##  provideToSP():
#
# - Triggers a LQTY issuance, based on time passed since the last issuance. The LQTY issuance is shared between *all* depositors and front ends
# - Tags the deposit with the provided front end tag param, if it's a new deposit
# - Sends depositor's accumulated gains (LQTY, ETH) to depositor
# - Sends the tagged front end's accumulated LQTY gains to the tagged front end
# - Increases deposit and tagged front end's stake, and takes new snapshots for each.
##
@external
def provide_to_sp(amount: uint256, frontend_tag: address):
    self._require_frontend_is_registered_or_zero(frontend_tag)
    self._require_frontend_not_registered(msg.sender)
    self._require_non_zero_amount(amount)

    initial_deposit: uint256 = self.deposits[msg.sender].initialValue

    #ICommunityIssuance communityIssuanceCached = communityIssuance

    #_triggerLQTYIssuance(communityIssuanceCached)

    if (initial_deposit == 0): self._set_frontend_tag(msg.sender, frontend_tag)
    depositor_eth_gain: uint256 = self._get_depositor_eth_gain(msg.sender)

    compounded_lusd_deposit: uint256 = self.get_compounded_lusd_deposit(msg.sender)
    lusd_loss: uint256 = initial_deposit - compounded_lusd_deposit # Needed only for event log

    # First pay out any LQTY gains
    frontend: address = self.deposits[msg.sender].frontendTag
    #_payOutLQTYGains(communityIssuanceCached, msg.sender, frontEnd)

    # Update front end stake
    compounded_frontend_stake: uint256 = self.get_compounded_frontend_stake(frontend)
    new_frontend_stake: uint256 = compounded_frontend_stake + amount

    self._update_frontend_stake_and_snapshots(frontend, new_frontend_stake)
    log FrontendStakeChanged(frontend, new_frontend_stake, msg.sender)

    self._send_lusd_to_stability_pool(msg.sender, amount)

    new_deposit: uint256 = compounded_lusd_deposit + amount

    self._update_deposit_and_snapshots(msg.sender, new_deposit)
    log UserDepositChanged(msg.sender, new_deposit)

    log ETHGainWithdrawn(msg.sender, depositor_eth_gain, lusd_loss) # RD loss required for event log

    self._send_eth_gain_to_depositor(depositor_eth_gain)


##  withdrawFromSP():
#
# - Triggers a LQTY issuance, based on time passed since the last issuance. The LQTY issuance is shared between *all* depositors and front ends
# - Removes the deposit's front end tag if it is a full withdrawal
# - Sends all depositor's accumulated gains (LQTY, ETH) to depositor
# - Sends the tagged front end's accumulated LQTY gains to the tagged front end
# - Decreases deposit and tagged front end's stake, and takes new snapshots for each.
#
# If _amount > userDeposit, the user withdraws all of their compounded deposit.
##
@external
def withdraw_from_sp(amount: uint256):
    if amount == 0: self._require_no_undercollateralized_troves()
    initial_deposit: uint256 = self.deposits[msg.sender].initialValue
    self._require_user_has_deposit(initial_deposit)

    #ICommunityIssuance communityIssuanceCached = communityIssuance
    #_triggerLQTYIssuance(communityIssuanceCached)

    depositor_eth_gain: uint256 = self._get_depositor_eth_gain(msg.sender)
    compounded_lusd_deposit: uint256 = self.get_compounded_lusd_deposit(msg.sender)

    lusd_to_withdraw: uint256 = min(amount, compounded_lusd_deposit)
    lusd_loss: uint256 = initial_deposit - compounded_lusd_deposit# Needed only for event log

    # First pay out any LQTY gains
    frontend: address = self.deposits[msg.sender].frontendTag
    #_payOutLQTYGains(communityIssuanceCached, msg.sender, frontEnd)

    # Update front end stake
    compounded_frontend_stake: uint256 = self.get_compounded_frontend_stake(frontend)
    new_frontend_stake: uint256 = compounded_frontend_stake - lusd_to_withdraw

    self._update_frontend_stake_and_snapshots(frontend, new_frontend_stake)
    log FrontendStakeChanged(frontend, new_frontend_stake, msg.sender)

    self._send_lusd_to_depositor(msg.sender, lusd_to_withdraw)

    # Update deposit
    new_deposit: uint256 = compounded_lusd_deposit - lusd_to_withdraw
    self._update_deposit_and_snapshots(msg.sender, new_deposit)

    log UserDepositChanged(msg.sender, new_deposit)

    log ETHGainWithdrawn(msg.sender, depositor_eth_gain, lusd_loss) # RD loss required for event log
    self._send_eth_gain_to_depositor(depositor_eth_gain)

## function withdrawETHGainToTrove


# --- LQTY issuance functions ---
@internal
def _trigger_gov_issuance(community_issuance: ICommunityIssuance):
    gov_issuance: uint256 = extcall self.community_issuance.issue_gov()
    self._update_g(gov_issuance)

@internal
def _update_g(gov_issuance: uint256):
    total_rd: uint256 = self.total_lusd_deposits
    ##  
    # When total deposits is 0, G is not updated. In this case, the LQTY issued can not be obtained by later
    # depositors - it is missed out on, and remains in the balanceof the CommunityIssuance contract.
    #
    ## 
    if (total_rd == 0 or  gov_issuance == 0): return

    gov_per_unit_staked: uint256 = self._compute_gov_per_unit_staked(gov_issuance, total_rd)

    marginal_gov_gain: uint256 = gov_per_unit_staked * self.P

    self.epoch_to_scale_to_g[self.current_epoch][self.current_scale] += marginal_gov_gain

    log G_Updated(self.epoch_to_scale_to_g[self.current_epoch][self.current_scale],
                  self.current_epoch, self.current_scale)


@internal
def _compute_gov_per_unit_staked(gov_issuance: uint256, total_lusd_deposits: uint256) -> uint256:
    ## 
    # Calculate the LQTY-per-unit staked.  Division uses a "feedback" error correction, to keep the
    # cumulative error low in the running total G:
    #
    # 1) Form a numerator which compensates for the floor division error that occurred the last time this
    # function was called.
    # 2) Calculate "per-unit-staked" ratio.
    # 3) Multiply the ratio back by its denominator, to reveal the current floor division error.
    # 4) Store this error for use in the next correction when this function is called.
    # 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
    ##
    gov_numerator: uint256 = (gov_issuance * 10**10) + self.last_gov_error
    gov_per_unit_staked: uint256 = gov_numerator // total_lusd_deposits
    self.last_gov_error = gov_numerator - (gov_per_unit_staked * total_lusd_deposits)

    return gov_per_unit_staked


# --- Liquidation functions ---

##
# Cancels out the specified debt against the LUSD contained in the Stability Pool (as far as possible)
# and transfers the Trove's ETH collateral from ActivePool to StabilityPool.
# Only called by liquidation functions in the TroveManager.
##
@external
def offset(debt_to_offset: uint256, coll_to_add: uint256):
    self._require_caller_is_trove_manager()
    total_rd: uint256 = self.total_lusd_deposits # cached to save an SLOAD
    if total_rd == 0 or debt_to_offset == 0: return

    self._trigger_gov_issuance(self.community_issuance)
    
    eth_gain_per_unit_staked: uint256 = 0
    lusd_loss_per_unit_staked: uint256 = 0

    eth_gain_per_unit_staked, lusd_loss_per_unit_staked = self._compute_rewards_per_unit_staked(coll_to_add, debt_to_offset, total_rd)

    self._update_reward_sum_and_product(eth_gain_per_unit_staked, lusd_loss_per_unit_staked)# updates S and P

    self._move_offset_coll_and_debt(coll_to_add, debt_to_offset)

# --- Offset helper functions ---
@internal
def _compute_rewards_per_unit_staked(coll_to_add: uint256, debt_to_offset: uint256,
                                     total_lusd_deposits: uint256) -> (uint256, uint256):

    ##
    # Compute the LUSD and ETH rewards. Uses a "feedback" error correction, to keep
    # the cumulative error in the P and S state variables low:
    #
    # 1) Form numerators which compensate for the floor division errors that occurred the last time this 
    # function was called.  
    # 2) Calculate "per-unit-staked" ratios.
    # 3) Multiply each ratio back by its denominator, to reveal the current floor division error.
    # 4) Store these errors for use in the next correction when this function is called.
    # 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
    ##

    eth_numerator: uint256 = coll_to_add * 10**18 + self.last_eth_error_offset

    assert debt_to_offset <= total_lusd_deposits
    lusd_loss_per_unit_staked: uint256 = 0
    if debt_to_offset == total_lusd_deposits:
        lusd_loss_per_unit_staked = 10**18 # When the Pool depletes to 0, so does each deposit 
        self.last_lusd_loss_error_offset = 0
    else:
        lusd_loss_numerator: uint256 = debt_to_offset * 10**18 - self.last_lusd_loss_error_offset 
        ##
        # Add 1 to make error in quotient positive. We want "slightly too much" LUSD loss,
        # which ensures the error in any given compoundedLUSDDeposit favors the Stability Pool.
        ##
        lusd_loss_per_unit_staked = lusd_loss_numerator//total_lusd_deposits + 1
        self.last_lusd_loss_error_offset = lusd_loss_per_unit_staked * total_lusd_deposits - lusd_loss_numerator


    eth_gain_per_unit_staked: uint256 = eth_numerator//total_lusd_deposits
    self.last_eth_error_offset = eth_numerator - (eth_gain_per_unit_staked * total_lusd_deposits)

    return (eth_gain_per_unit_staked, lusd_loss_per_unit_staked)


@internal
def _update_reward_sum_and_product(eth_gas_per_unit_staked: uint256, lusd_loss_per_unit_staked: uint256):
    current_P: uint256 = self.P
    new_P: uint256 = 0

    assert lusd_loss_per_unit_staked <= 10**18

    ##
    # The newProductFactor is the factor by which to change all deposits, due to the depletion of Stability Pool LUSD in the liquidation.
    # We make the product factor 0 if there was a pool-emptying. Otherwise, it is (1 - LUSDLossPerUnitStaked)
    ##

    new_product_factor: uint256 = 10**18 - lusd_loss_per_unit_staked

    current_scale_cached: uint128 = self.current_scale
    current_epoch_cached: uint128 = self.current_epoch

    current_S: uint256 = self.epoch_to_scale_to_sum[current_epoch_cached][current_scale_cached]

    ##
    # Calculate the new S first, before we update P.
    # The ETH gain for any given depositor from a liquidation depends on the value of their deposit
    # (and the value of totalDeposits) prior to the Stability being depleted by the debt in the liquidation.
    #
    # Since S corresponds to ETH gain, and P to deposit loss, we update S first.
    ##

    marginal_eth_gain: uint256 = eth_gas_per_unit_staked * current_P
    new_S: uint256 = current_S + marginal_eth_gain
    self.epoch_to_scale_to_sum[current_epoch_cached][current_scale_cached] = new_S
    log S_Updated(new_S, current_epoch_cached, current_scale_cached)

    # If the Stability Pool was emptied, increment the epoch, and reset the scale and product P
    if (new_product_factor == 0):
        self.current_epoch = current_epoch_cached + 1
        log EpochUpdated(self.current_epoch)
        self.current_scale = 0
        log ScaleUpdated(self.current_scale)
        new_P = 10 ** 18
    # If multiplying P by a non-zero product factor would reduce P below the scale boundary, increment the scale
    elif current_P * new_product_factor // 10**18 < SCALE_FACTOR:
        new_P = current_P * new_product_factor * SCALE_FACTOR // 10**18
        self.current_scale = current_scale_cached + 1
        log ScaleUpdated(self.current_scale)
    else:
        new_P = current_P * new_product_factor // 10**18

    assert new_P > 0
    self.P = new_P

    log P_Updated(new_P)


@internal
def _move_offset_coll_and_debt(coll_to_add: uint256, debt_to_offset: uint256):
    active_pool_cached: IActivePool = self.active_pool
    # Cancel the liquidated LUSD debt with the LUSD in the stability pool
    extcall active_pool_cached.decrease_lusd_debt(debt_to_offset)
    self._decrease_lusd(debt_to_offset)

    # Burn the debt that was successfully offset
    extcall self.lusd_token.burn(self, debt_to_offset)

    extcall active_pool_cached.send_eth(self, coll_to_add)


@internal
def _decrease_lusd(amount: uint256):
    self.total_lusd_deposits -= amount
    log StabilityPoolRDBalanceUpdated(self.total_lusd_deposits)

# --- Reward calculator functions for depositor and front end ---

## Calculates the ETH gain earned by the deposit since its last snapshots were taken.
# Given by the formula:  E = d0 * (S - S(0))/P(0)
# where S(0) and P(0) are the depositor's snapshots of the sum S and product P, respectively.
# d0 is the last recorded deposit value.
##
@view
def _get_depositor_eth_gain(depositor: address) -> uint256:
    initial_deposit: uint256 = self.deposits[depositor].initialValue
    if initial_deposit == 0: return 0

    #Snapshots memory snapshots = depositSnapshots[_depositor]
    snapshots: Snapshots  = self.deposit_snapshots[depositor]

    eth_gain: uint256 = self._get_eth_gain_from_snapshots(initial_deposit, snapshots)

    return eth_gain

@external
@view
def get_depositor_eth_gain(depositor: address) -> uint256:
    return self._get_depositor_eth_gain(depositor)

@view
def _get_eth_gain_from_snapshots(initial_deposit: uint256, snapshots: Snapshots) -> uint256:
    ## 
    # Grab the sum 'S' from the epoch at which the stake was made. The ETH gain may span up to one scale change.
    # If it does, the second portion of the ETH gain is scaled by 1e9.
    # If the gain spans no scale change, the second portion will be 0.
    ##
    epoch_snapshot: uint128 = snapshots.epoch
    scale_snapshot: uint128 = snapshots.scale
    S_snapshot: uint256 = snapshots.S
    P_snapshot: uint256 = snapshots.P


    first_portion: uint256 = self.epoch_to_scale_to_sum[epoch_snapshot][scale_snapshot] - S_snapshot
    second_portion: uint256 = self.epoch_to_scale_to_sum[epoch_snapshot][scale_snapshot + 1] // SCALE_FACTOR

    eth_gain: uint256 = initial_deposit * (first_portion + second_portion) // P_snapshot // 10**18

    return eth_gain

##
# Calculate the LQTY gain earned by a deposit since its last snapshots were taken.
# Given by the formula:  LQTY = d0 * (G - G(0))/P(0)
# where G(0) and P(0) are the depositor's snapshots of the sum G and product P, respectively.
# d0 is the last recorded deposit value.
##
@view
def _get_depositor_gov_gain(depositor: address) -> uint256:
    initial_deposit: uint256 = self.deposits[depositor].initialValue
    if initial_deposit == 0: return 0

    frontendTag: address = self.deposits[depositor].frontendTag

    ## 
    # If not tagged with a front end, the depositor gets a 100% cut of what their deposit earned.
    # Otherwise, their cut of the deposit's earnings is equal to the kickbackRate, set by the front end through
    # which they made their deposit.
    ##

    #kickback_rate: uint256 = (frontendTag == empty(address)) ? 10**18 : self.frontends[frontendTag].kickbackRate
    kickback_rate: uint256 = 10**18 if frontendTag == empty(address) else self.frontends[frontendTag].kickbackRate

    snapshots: Snapshots = self.deposit_snapshots[depositor]

    gov_gain: uint256 = kickback_rate * self._get_gov_gain_from_snapshots(initial_deposit, snapshots) // 10**18

    return gov_gain

@external
@view
def get_depositor_gov_gain(depositor: address) -> uint256:
    return self._get_depositor_gov_gain(depositor)

##
# Return the LQTY gain earned by the front end. Given by the formula:  E = D0 * (G - G(0))/P(0)
# where G(0) and P(0) are the depositor's snapshots of the sum G and product P, respectively.
#
# D0 is the last recorded value of the front end's total tagged deposits.
##
@view
def _get_frontend_gov_gain(frontend: address) -> uint256:
    frontend_stake: uint256 = self.frontend_stakes[frontend]
    if frontend_stake == 0: return 0

    kickback_rate: uint256 = self.frontends[frontend].kickbackRate
    frontend_share: uint256  = 10**18 - kickback_rate

    snapshots: Snapshots = self.frontend_snapshots[frontend]

    gov_gain: uint256 = frontend_share * self._get_gov_gain_from_snapshots(frontend_stake, snapshots) // 10**18
    return gov_gain

@external
@view
def get_frontend_gov_gain(frontend: address) -> uint256:
    return self._get_frontend_gov_gain(frontend)

@internal
@view
def _get_gov_gain_from_snapshots(initial_stake: uint256, snapshots: Snapshots) -> uint256:
    ## 
    # Grab the sum 'G' from the epoch at which the stake was made. The LQTY gain may span up to one scale change.
    # If it does, the second portion of the LQTY gain is scaled by 1e9.
    # If the gain spans no scale change, the second portion will be 0.
    ## 

    epoch_snapshot: uint128 = snapshots.epoch
    scale_snapshot: uint128 = snapshots.scale
    g_snapshot: uint256 = snapshots.G
    p_snapshot: uint256 = snapshots.P

    first_portion: uint256 = self.epoch_to_scale_to_g[epoch_snapshot][scale_snapshot] - g_snapshot
    second_portion: uint256 = self.epoch_to_scale_to_g[epoch_snapshot][scale_snapshot + 1] // SCALE_FACTOR

    gov_gain: uint256 = initial_stake * (first_portion + second_portion) // p_snapshot // 10**18

    return gov_gain


# --- Compounded deposit and compounded front end stake ---

##
# Return the user's compounded deposit. Given by the formula:  d = d0 * P/P(0)
# where P(0) is the depositor's snapshot of the product P, taken when they last updated their deposit.
##
@view
def get_compounded_lusd_deposit(depositor: address) -> uint256:
    initial_deposit: uint256 = self.deposits[depositor].initialValue
    if initial_deposit == 0: return 0

    snapshots: Snapshots  = self.deposit_snapshots[depositor]

    compounded_deposit: uint256 = self._get_compounded_stake_from_snapshots(initial_deposit, snapshots)
    return compounded_deposit

##
# Return the front end's compounded stake. Given by the formula:  D = D0 * P/P(0)
# where P(0) is the depositor's snapshot of the product P, taken at the last time
# when one of the front end's tagged deposits updated their deposit.
#
# The front end's compounded stake is equal to the sum of its depositors' compounded deposits.
#
def get_compounded_frontend_stake(frontend: address) -> uint256:
    frontend_stake: uint256 = self.frontend_stakes[frontend]
    if frontend_stake == 0: return 0

    snapshots: Snapshots = self.frontend_snapshots[frontend]

    compounded_frontend_stake: uint256 = self._get_compounded_stake_from_snapshots(frontend_stake, snapshots)
    return compounded_frontend_stake

# Internal function, used to calculcate compounded deposits and compounded front end stakes.
@internal
@view
def _get_compounded_stake_from_snapshots(initial_stake: uint256, snapshots: Snapshots) -> uint256:
    snapshot_P: uint256 = snapshots.P
    epoch_snapshot: uint128 = snapshots.epoch
    scale_snapshot: uint128 = snapshots.scale

    # If stake was made before a pool-emptying event, then it has been fully cancelled with debt -- so, return 0
    if epoch_snapshot < self.current_epoch: return 0

    scale_diff: uint128 = self.current_scale - scale_snapshot

    compounded_stake: uint256 = 0
    ##* Compute the compounded stake. If a scale change in P was made during the stake's lifetime,
    # account for it. If more than one scale change was made, then the stake has decreased by a factor of
    # at least 1e-9 -- so return 0.
    ##
    if scale_diff == 0:
        compounded_stake = initial_stake * self.P // snapshot_P
    elif scale_diff == 1:
        compounded_stake = initial_stake * self.P // snapshot_P // SCALE_FACTOR
    else: # if scale_diff >= 2
        compounded_stake = 0

    ## 
    # If compounded deposit is less than a billionth of the initial deposit, return 0.
    #
    # NOTE: originally, this line was in place to stop rounding errors making the deposit too large. However, the error
    # corrections should ensure the error in P "favors the Pool", i.e. any given compounded deposit should slightly less
    # than it's theoretical value.
    #
    # Thus it's unclear whether this line is still really needed.
    ##
    if compounded_stake < initial_stake // 10**9:
        return 0

    return compounded_stake

# --- Sender functions for RD deposit, ETH gains and LQTY gains ---
        
##  Transfer the RD tokens from the user to the Stability Pool's address, and update its recorded RD
@internal
def _send_lusd_to_stability_pool(addr: address, amount: uint256):
    extcall self.lusd_token.send_to_pool(addr, self, amount)
    self.total_lusd_deposits += amount
    log StabilityPoolRDBalanceUpdated(self.total_lusd_deposits)
@internal
def _send_eth_gain_to_depositor(amount: uint256):
    #if amount == 0: return

    self.eth -= amount
    log StabilityPoolETHBalanceUpdated(self.eth)
    log EtherSent(msg.sender, amount)
    raw_call(msg.sender, b"", value=amount, revert_on_failure=True)
    #send(msg.sender, amount)

# Send LUSD to user and decrease LUSD in Pool
@internal
def _send_lusd_to_depositor(depositor: address, lusd_withdrawal: uint256):
    if lusd_withdrawal == 0: return

    extcall self.lusd_token.return_from_pool(self, depositor, lusd_withdrawal)

    self._decrease_lusd(lusd_withdrawal)

# --- External Front End functions ---

# Front end makes a one-time selection of kickback rate upon registering
@external
def register_frontend(kickback_rate: uint256):
    self._require_frontend_not_registered(msg.sender)
    self._require_user_has_no_deposit(msg.sender)
    self._require_valid_kickback_rate(kickback_rate)

    self.frontends[msg.sender].kickbackRate = kickback_rate
    self.frontends[msg.sender].registered = True

    log FrontendRegistered(msg.sender, kickback_rate)

# --- Stability Pool Deposit Functionality ---
@internal
def _set_frontend_tag(depositor: address, frontend_tag: address):
    self.deposits[depositor].frontendTag = frontend_tag
    log FrontendTagSet(depositor, frontend_tag)

@internal
def _update_deposit_and_snapshots(depositor: address, new_value: uint256):
    self.deposits[depositor].initialValue = new_value

    if new_value == 0:
        self.deposits[depositor].frontendTag = empty(address)
        self.deposit_snapshots[depositor] = Snapshots(S=0,P=0,G=0,scale=0,epoch=0)
        log DepositSnapshotUpdated(depositor, 0, 0, 0)
        return

    current_scale_cached: uint128 = self.current_scale
    current_epoch_cached: uint128 = self.current_epoch
    current_P: uint256 = self.P

    # Get S and G for the current epoch and current scale
    current_S: uint256 = self.epoch_to_scale_to_sum[current_epoch_cached][current_scale_cached]
    current_G: uint256 = self.epoch_to_scale_to_g[current_epoch_cached][current_scale_cached]

    # Record new snapshots of the latest running product P, sum S, and sum G, for the depositor
    self.deposit_snapshots[depositor].P = current_P
    self.deposit_snapshots[depositor].S = current_S
    self.deposit_snapshots[depositor].G = current_G
    self.deposit_snapshots[depositor].scale = current_scale_cached
    self.deposit_snapshots[depositor].epoch = current_epoch_cached

    log DepositSnapshotUpdated(depositor, current_P, current_S, current_G)


@internal
def _update_frontend_stake_and_snapshots(frontend: address, new_value: uint256):
    self.frontend_stakes[frontend] = new_value

    if new_value == 0:
        self.frontend_snapshots[frontend] = Snapshots(S=0,P=0,G=0,scale=0,epoch=0)
        log FrontendSnapshotUpdated(frontend, 0, 0)
        return

    current_scale_cached: uint128 = self.current_scale
    current_epoch_cached: uint128 = self.current_epoch
    current_P: uint256 = self.P

    # Get G for the current epoch and current scale
    current_G: uint256 = self.epoch_to_scale_to_g[current_epoch_cached][current_scale_cached]

    # Record new snapshots of the latest running product P and sum G for the front end
    self.frontend_snapshots[frontend].P = current_P
    self.frontend_snapshots[frontend].G = current_G
    self.frontend_snapshots[frontend].scale = current_scale_cached
    self.frontend_snapshots[frontend].epoch = current_epoch_cached

    log FrontendSnapshotUpdated(frontend, current_P, current_G)


@internal
def _pay_out_gov_gains(community_issuance: ICommunityIssuance, depositor: address, frontend: address):
    # Pay out front end's LQTY gain
    if frontend != empty(address):
        frontend_gov_gain: uint256 = self._get_frontend_gov_gain(frontend)
        extcall community_issuance.send_gov(frontend, frontend_gov_gain)
        log LQTYPaidToFrontEnd(frontend, frontend_gov_gain)

    # Pay out depositor's LQTY gain
    depositor_gov_gain: uint256 = self._get_depositor_gov_gain(depositor)
    extcall community_issuance.send_gov(depositor, depositor_gov_gain)
    log LQTYPaidToDepositor(depositor, depositor_gov_gain)

# --- 'require' functions ---

@internal
@view
def _require_caller_is_active_pool():
    assert msg.sender == self.active_pool.address, "StabilityPool: Caller is not ActivePool"

@internal
@view
def _require_caller_is_trove_manager():
    assert msg.sender == self.trove_manager.address, "StabilityPool: Caller is not TroveManager"

@internal
def _require_no_undercollateralized_troves():
    price: uint256 = extcall self.price_feed.fetch_price()
    lowest_trove: address = staticcall self.sorted_troves.get_last()
    icr: uint256 = staticcall self.trove_manager.get_current_icr(lowest_trove, price)
    assert icr >= MCR, "StabilityPool: Cannot withdraw while there are troves with ICR < MCR"

@internal
@view
def _require_user_has_deposit(amount: uint256):
    assert amount > 0, 'StabilityPool: User must have non-zero deposit'

@internal
@view
def _require_user_has_no_deposit(addr: address):
    assert self.deposits[addr].initialValue == 0, 'StabilityPool: User must have no deposit'

@internal
@pure
def _require_non_zero_amount(amount: uint256):
        assert amount > 0, 'StabilityPool: Amount must be non-zero'

@internal
@view
def _require_user_has_trove(depositor: address):
    assert staticcall self.trove_manager.get_trove_status(depositor) == 1, "StabilityPool: caller must have an active trove to withdraw ETHGain to"

@internal
@view
def _require_user_has_eth_gain(depositor: address):
    eth_gain: uint256 = self._get_depositor_eth_gain(depositor)
    assert eth_gain > 0, "StabilityPool: caller must have non-zero ETH Gain"

@internal
@view
def _require_frontend_not_registered(addr: address):
    assert not self.frontends[addr].registered, 'StabilityPool: front end must not already be registered'

@internal
@view
def _require_frontend_is_registered_or_zero(addr: address):
    assert self.frontends[addr].registered or addr == empty(address), 'StabilityPool: front end must already be registered or zero address'

@internal
@pure
def _require_valid_kickback_rate(kickback_rate: uint256):
    assert kickback_rate <= 10**18, "StabilityPool: Kickback rate must be in range [0,1]"

# --- Fallback function ---
@external
@payable
def __default__():
    self._require_caller_is_active_pool()
    self.eth += msg.value
    log StabilityPoolETHBalanceUpdated(self.eth)
