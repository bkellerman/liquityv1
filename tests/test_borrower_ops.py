import ape
import pytest
import boa

from util import set_sender, reset_sender, ZERO_ADDRESS
from fixtures import system, owner, alice, bob, frontend, system_addresses

class TestBorrowerOperations:
    def test(self, system):
        assert system['active_pool'].get_eth() == 0

    def test_open_trove(self, alice, system):
        set_sender(alice)
        fee = 10**18 // 1000 * 5
        debt_amount = 5000 * 10**18
        coll_amount = 10*10**18
        system['borrower_operations'].open_trove(fee,
                                                 debt_amount,
                                                 ZERO_ADDRESS,
                                                 ZERO_ADDRESS,
                                                 value=coll_amount)
        assert system['borrower_operations'].get_entire_system_coll() == coll_amount

        exp_debt = (((10**18 + fee) * 5000000000000000000000))//10**18 + (200 * 10**18)
        assert system['borrower_operations'].get_entire_system_debt() == exp_debt
