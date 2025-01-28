# SPDX-License-Identifier: MIT
# pragma version ~=0.4.0

from snekmate.auth import ownable

from interfaces import ITroveManager
import base

initializes: ownable

struct Node:
    exists: bool
    next_id: address  # Id of next node (smaller NICR) in the list
    prev_id: address  # Id of previous node (larger NICR) in the list

struct Data:
    head: address  # Head of the list. Also the node in the list with the largest NICR
    tail: address  # Tail of the list. Also the node in the list with the smallest NICR
    max_size: uint256  # Maximum size of the list
    size: uint256  # Current size of the list

nodes: HashMap[address, Node]  # Track the corresponding ids for each node in the list


event TroveManagerAddressChanged:
    new_address: address

event BorrowerOperationsAddressChanged:
    new_address: address

event NodeAdded:
    id: address
    nicr: uint256

event NodeRemoved:
    id: address

borrower_operations_address: public(address)
trove_manager: public(ITroveManager)
data: public(Data)

@deploy
def __init__():
    ownable.__init__()

@external
def set_params(size: uint256, trove_manager_address: address, borrower_operations_address: address):
    assert size > 0, "SortedTroves: size cannot be zero"
    assert size <= base.MAX_TROVES, "SortedTroves: size is too high"
    assert trove_manager_address != empty(address), "Invalid trove manager address"
    assert borrower_operations_address != empty(address), "Invalid borrower operations address"

    self.data.max_size = size
    self.trove_manager = ITroveManager(trove_manager_address)
    self.borrower_operations_address = borrower_operations_address

    log TroveManagerAddressChanged(trove_manager_address)
    log BorrowerOperationsAddressChanged(borrower_operations_address)

    ownable.owner = empty(address)

@external
def insert(id: address, nicr: uint256, prev_id: address, next_id: address):
    trove_manager_cached: ITroveManager = self.trove_manager

    self._require_caller_is_bo_or_trove_m(trove_manager_cached)
    self._insert(trove_manager_cached, id, nicr, prev_id, next_id)

@internal
def _insert(trove_manager: ITroveManager, id: address, nicr: uint256, prev_id: address, next_id: address):
    assert not self._is_full(), "SortedTroves: List is full"
    assert not self._contains(id), "SortedTroves: List already contains the node"
    assert id != empty(address), "SortedTroves: Id cannot be zero"
    assert nicr > 0, "SortedTroves: NICR must be positive"

    #prev_id: address = prev_id
    #next_id: address = next_id

    if not self._valid_insert_position(trove_manager, nicr, prev_id, next_id):
        prev_id, next_id = self._find_insert_position(trove_manager, nicr, prev_id, next_id)

    self.nodes[id].exists = True

    if prev_id == empty(address) and next_id == empty(address):
        self.data.head = id
        self.data.tail = id
    elif prev_id == empty(address):
        self.nodes[id].next_id = self.data.head
        self.nodes[self.data.head].prev_id = id
        self.data.head = id
    elif next_id == empty(address):
        self.nodes[id].prev_id = self.data.tail
        self.nodes[self.data.tail].next_id = id
        self.data.tail = id
    else:
        self.nodes[id].next_id = next_id
        self.nodes[id].prev_id = prev_id
        self.nodes[prev_id].next_id = id
        self.nodes[next_id].prev_id = id

    self.data.size += 1
    log NodeAdded(id, nicr)

@external
def remove(id: address):
    self._require_caller_is_trove_manager()
    self._remove(id)

@internal
def _remove(id: address):
    assert self._contains(id), "SortedTroves: List does not contain the id"

    if self.data.size > 1:
        if id == self.data.head:
            self.data.head = self.nodes[id].next_id
            self.nodes[self.data.head].prev_id = empty(address)
        elif id == self.data.tail:
            self.data.tail = self.nodes[id].prev_id
            self.nodes[self.data.tail].next_id = empty(address)
        else:
            self.nodes[self.nodes[id].prev_id].next_id = self.nodes[id].next_id
            self.nodes[self.nodes[id].next_id].prev_id = self.nodes[id].prev_id
    else:
        self.data.head = empty(address)
        self.data.tail = empty(address)

    self.nodes[id] = empty(Node)
    self.data.size -= 1
    log NodeRemoved(id)

@external
def re_insert(id: address, new_nicr: uint256, prev_id: address, next_id: address):
    trove_manager_cached: ITroveManager = self.trove_manager

    self._require_caller_is_bo_or_trove_m(trove_manager_cached)
    assert self._contains(id), "SortedTroves: List does not contain the id"
    assert new_nicr > 0, "SortedTroves: NICR must be positive"

    self._remove(id)
    self._insert(trove_manager_cached, id, new_nicr, prev_id, next_id)

@external
@view
def contains(id: address) -> bool:
    return self._contains(id)

@internal
@view
def _contains(id: address) -> bool:
    return self.nodes[id].exists

@external
@view
def is_full() -> bool:
   return self._is_full()

@internal
@view
def _is_full() -> bool:
    return self.data.size == self.data.max_size

@external
@view
def is_empty() -> bool:
    return self._is_empty()

@internal
@view
def _is_empty() -> bool:
    return self.data.size == 0

@external
@view
def get_size() -> uint256:
    return self._get_size()

@internal
@view
def _get_size() -> uint256:
    return self.data.size

@external
@view
def get_max_size() -> uint256:
    return self._get_max_size()

@internal
@view
def _get_max_size() -> uint256:
    return self.data.max_size

@external
@view
def get_first() -> address:
    return self.data.head

@external
@view
def get_last() -> address:
    return self.data.tail

@external
@view
def get_next(id: address) -> address:
    return self.nodes[id].next_id

@external
@view
def get_prev(id: address) -> address:
    return self.nodes[id].prev_id

@external
@view
def valid_insert_position(nicr: uint256, prev_id: address, next_id: address) -> bool:
    return self._valid_insert_position(self.trove_manager, nicr, prev_id, next_id)

@internal
@view
def _valid_insert_position(trove_manager: ITroveManager, nicr: uint256, prev_id: address, next_id: address) -> bool:
    if prev_id == empty(address) and next_id == empty(address):
        return self._is_empty()
    elif prev_id == empty(address):
        return self.data.head == next_id and nicr >= staticcall trove_manager.get_nominal_icr(next_id)
    elif next_id == empty(address):
        return self.data.tail == prev_id and nicr <= staticcall trove_manager.get_nominal_icr(prev_id)
    else:
        return (self.nodes[prev_id].next_id == next_id and
                staticcall trove_manager.get_nominal_icr(prev_id) >= nicr and
                nicr >= staticcall trove_manager.get_nominal_icr(next_id))

@internal
@view
def _descend_list(trove_manager: ITroveManager, nicr: uint256, start_id: address) -> (address, address):
    if self.data.head == start_id and nicr >= staticcall trove_manager.get_nominal_icr(start_id):
        return empty(address), start_id

    prev_id: address = start_id
    next_id: address = self.nodes[prev_id].next_id

    for _: uint256 in range(self._get_size(), bound=base.MAX_TROVES):
        if prev_id == empty(address) or self._valid_insert_position(trove_manager, nicr, prev_id, next_id):
            break

        prev_id = self.nodes[prev_id].next_id
        next_id = self.nodes[prev_id].next_id

    return prev_id, next_id

@internal
@view
def _ascend_list(trove_manager: ITroveManager, nicr: uint256, start_id: address) -> (address, address):
    if self.data.tail == start_id and nicr <= staticcall trove_manager.get_nominal_icr(start_id):
        return start_id, empty(address)

    next_id: address = start_id
    prev_id: address = self.nodes[next_id].prev_id

    for _: uint256 in range(self._get_size(), bound=base.MAX_TROVES):
        if next_id == empty(address) or self._valid_insert_position(trove_manager, nicr, prev_id, next_id):
            break

        next_id = self.nodes[next_id].prev_id
        prev_id = self.nodes[next_id].prev_id

    return prev_id, next_id

@external
@view
def find_insert_position(nicr: uint256, prev_id: address, next_id: address) -> (address, address):
    return self._find_insert_position(self.trove_manager, nicr, prev_id, next_id)

@internal
@view
def _find_insert_position(trove_manager: ITroveManager, nicr: uint256, prev_id: address, next_id: address) -> (address, address):
    #prev_id: address = prev_id
    #next_id: address = next_id

    if prev_id != empty(address):
        if not self._contains(prev_id) or nicr > staticcall trove_manager.get_nominal_icr(prev_id):
            prev_id = empty(address)

    if next_id != empty(address):
        if not self._contains(next_id) or nicr < staticcall trove_manager.get_nominal_icr(next_id):
            next_id = empty(address)

    if prev_id == empty(address) and next_id == empty(address):
        return self._descend_list(trove_manager, nicr, self.data.head)
    elif prev_id == empty(address):
        return self._ascend_list(trove_manager, nicr, next_id)
    elif next_id == empty(address):
        return self._descend_list(trove_manager, nicr, prev_id)
    else:
        return self._descend_list(trove_manager, nicr, prev_id)

@internal
@view
def _require_caller_is_trove_manager():
    assert msg.sender == self.trove_manager.address, "SortedTroves: Caller is not the TroveManager"

@internal
@view
def _require_caller_is_bo_or_trove_m(trove_manager: ITroveManager):
    assert msg.sender == self.borrower_operations_address or msg.sender == trove_manager.address, "SortedTroves: Caller is neither BO nor TroveM"

