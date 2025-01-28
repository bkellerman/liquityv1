# SPDX-License-Identifier: MIT
# pragma version ~=0.4.0

from snekmate.auth import ownable
from snekmate.utils import ecdsa
initializes: ownable

from interfaces import ITroveManager
from interfaces import ILUSDToken
from interfaces import IActivePool
from interfaces import IDefaultPool
from interfaces import IPriceFeed
from interfaces import ISortedTroves
from interfaces import ILQTYStaking
from interfaces import ICollSurplusPool
from interfaces import ILockupContractFactory

import math

# --- Constants ---
NAME: constant(String[32]) = "LQTY"
SYMBOL: constant(String[32]) = "LQTY"
VERSION: constant(String[32]) = "1"
DECIMALS: constant(uint8) = 18
ONE_YEAR_IN_SECONDS: constant(uint256) = 31536000
ONE_MILLION: constant(uint256) = 10**24

PERMIT_TYPE_HASH: constant(bytes32) = keccak256(b"Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
TYPE_HASH: constant(bytes32) = keccak256(b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")

# --- State Variables ---

total_supply: public(uint256)

balances: HashMap[address, uint256]
allowances: HashMap[address, HashMap[address, uint256]]

nonces: public(HashMap[address, uint256])

cached_domain_separator: immutable(bytes32)
cached_chain_id: immutable(uint256)

hashed_name: immutable(bytes32)
hashed_version: immutable(bytes32)

deployment_start_time: immutable(uint256)
multisig_address: public(address)

community_issuance_address: public(address)
gov_staking_address: public(address)

lp_rewards_entitlement: immutable(uint256)
lockup_contract_factory: public(ILockupContractFactory)

# --- Events ---

event CommunityIssuanceAddressSet:
    community_issuance_address: address
event LQTYStakingAddressSet:
    gov_staking_address: address
event LockupContractFactoryAddressSet:
    lockup_contract_factory_address: address


@deploy
def __init__(
    community_issuance_address: address,
    gov_staking_address: address,
    lockup_factory_address: address,
    bounty_address: address,
    lp_rewards_address: address,
    multisig_address: address
):
    ownable.__init__()
    self.multisig_address = multisig_address
    deployment_start_time = block.timestamp

    self.community_issuance_address = community_issuance_address
    self.gov_staking_address = gov_staking_address
    self.lockup_contract_factory = ILockupContractFactory(lockup_factory_address)

    hashed_name = keccak256(NAME)
    hashed_version = keccak256(VERSION)
    cached_chain_id = chain.id
    cached_domain_separator = self._build_domain_separator()

    bounty_entitlement: uint256 = ONE_MILLION * 2
    self._mint(bounty_address, bounty_entitlement)

    depositors_and_front_ends_entitlement: uint256 = ONE_MILLION * 32
    self._mint(community_issuance_address, depositors_and_front_ends_entitlement)

    lp_rewards_entitlement = ONE_MILLION * 4 // 3
    self._mint(lp_rewards_address, lp_rewards_entitlement)

    multisig_entitlement: uint256 = ONE_MILLION * 100 - bounty_entitlement - depositors_and_front_ends_entitlement - lp_rewards_entitlement
    self._mint(multisig_address, multisig_entitlement)


@external
@view
def totalSupply() -> uint256:
    return self.total_supply

@external
@view
def balanceOf(account: address) -> uint256:
    return self.balances[account]

@external
@view
def get_deployment_start_time() -> uint256:
    return deployment_start_time

@external
@view
def get_lp_rewards_entitlement() -> uint256:
    return lp_rewards_entitlement

@external
def transfer(recipient: address, amount: uint256) -> bool:
    assert recipient != empty(address) and recipient != self
    self._transfer(msg.sender, recipient, amount)
    return True

@external
def approve(spender: address, amount: uint256) -> bool:
    self.allowances[msg.sender][spender] = amount
    return True

@external
def transfer_from(sender: address, recipient: address, amount: uint256) -> bool:
    assert self.allowances[sender][msg.sender] >= amount
    self._transfer(sender, recipient, amount)
    self.allowances[sender][msg.sender] -= amount
    return True

@external
def increase_allowance(spender: address, added_value: uint256) -> bool:
    assert not self._is_first_year() or msg.sender != self.multisig_address
    self.allowances[msg.sender][spender] += added_value
    return True

@external
def decrease_allowance(spender: address, subtracted_value: uint256) -> bool:
    assert not self._is_first_year() or msg.sender != self.multisig_address
    assert self.allowances[msg.sender][spender] >= subtracted_value
    self.allowances[msg.sender][spender] -= subtracted_value
    return True

@external
def send_to_gov_staking(sender: address, amount: uint256):
    assert msg.sender == self.gov_staking_address
    assert not self._is_first_year() or sender != self.multisig_address
    self._transfer(sender, self.gov_staking_address, amount)

@external
@view
def domain_separator() -> bytes32:
    return self._domain_separator()

@internal
@view
def _domain_separator() -> bytes32:
    return cached_domain_separator if chain.id == cached_chain_id else self._build_domain_separator()


@external
def permit(
    owner: address,
    spender: address,
    amount: uint256,
    deadline: uint256,
    v: uint8,
    r: bytes32,
    s: bytes32
):
    assert deadline >= block.timestamp, "LQTY: expired deadline"
    digest: bytes32 = keccak256(
        concat(
            b"\x19\x01",
            self._domain_separator(),
            keccak256(
                abi_encode(
                    PERMIT_TYPE_HASH,
                    owner,
                    spender,
                    amount,
                    self.nonces[owner],
                    deadline
                )
            )
        )
    )
    recovered_address: address = ecrecover(digest, v, r, s)
    assert recovered_address == owner, "LQTY: invalid signature"
    self.nonces[owner] += 1
    self.allowances[owner][spender] = amount



@external
@view
def get_nonce(owner: address) -> uint256:
    return self.nonces[owner]


@internal
@view
def _chain_id() -> uint256:
    return chain.id

@internal
@view
def _build_domain_separator() -> bytes32:
    return keccak256(concat(
        TYPE_HASH,
        hashed_name,
        hashed_version,
        convert(self._chain_id(), bytes32),
        convert(self, bytes32)
    ))

@internal
def _transfer(sender: address, recipient: address, amount: uint256):
    assert sender != empty(address) and recipient != empty(address)
    assert self.balances[sender] >= amount
    self.balances[sender] -= amount
    self.balances[recipient] += amount

@internal
def _mint(account: address, amount: uint256):
    assert account != empty(address)
    self.total_supply += amount
    self.balances[account] += amount

@internal
def _approve(owner: address, spender: address, amount: uint256):
    assert owner != empty(address) and spender != empty(address)
    self.allowances[owner][spender] = amount

@internal
@view
def _caller_is_multisig() -> bool:
    return msg.sender == self.multisig_address

@internal
@view
def _is_first_year() -> bool:
    return block.timestamp - deployment_start_time < ONE_YEAR_IN_SECONDS

@internal
@view
def _require_valid_recipient(recipient: address):
    assert recipient != empty(address) and recipient != self
    assert recipient != self.community_issuance_address and recipient != self.gov_staking_address

@internal
@view
def _require_recipient_is_registered_lc(recipient: address):
    assert staticcall self.lockup_contract_factory.is_registered_lockup(recipient)

@internal
@view
def _require_sender_is_not_multisig(sender: address):
    assert sender != self.multisig_address

@internal
@view
def _require_caller_is_not_multisig():
    assert not self._caller_is_multisig()

@internal
@view
def _require_caller_is_gov_staking():
    assert msg.sender == self.gov_staking_address

# --- Optional functions ---

@external
@view
def name() -> String[32]:
    return NAME

@external
@view
def symbol() -> String[32]:
    return SYMBOL

@external
@view
def decimals() -> uint8:
    return DECIMALS

@external
@view
def version() -> String[32]:
    return VERSION

@external
@view
def permit_type_hash() -> bytes32:
    return PERMIT_TYPE_HASH

