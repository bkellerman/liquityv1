import ape
import pytest
import boa
from util import set_sender, reset_sender, ZERO_ADDRESS, print_addresses
from fixtures import system, owner, alice, bob, charlie, frontend, system_addresses

class TestVaultManager:
    def test_liquidate(self, system, alice, bob, charlie, owner):
        # create trove
        set_sender(alice)
        fee = 10**18 // 1000 * 5
        debt_amount = 5000 * 10**18
        coll_amount = 10*10**18
        system['borrower_operations'].open_trove(fee,
                                                 debt_amount,
                                                 ZERO_ADDRESS,
                                                 ZERO_ADDRESS,
                                                 value=coll_amount)

        # create trove #2, critical
        set_sender(charlie)
        fee = 10**18 // 1000 * 5
        coll_amount = 10*10**18
        coll_price = system['price_feed'].fetch_price()
        MCR = 10**18 + 10**17
        debt_amount = int(10**18/MCR * coll_price * coll_amount // 10**18) - 200*10**18
        system['borrower_operations'].open_trove(fee,
                                                 debt_amount,
                                                 ZERO_ADDRESS,
                                                 ZERO_ADDRESS,
                                                 value=coll_amount)

        # provide to sp
        set_sender(bob)
        system['stability_pool'].provide_to_sp(10000 * 10**18, ZERO_ADDRESS)

        # drop collateral price
        set_sender(owner)
        fee = 10**18 // 1000 * 5
        coll_price -= 100 * 10**18
        system['price_aggregator'].set_price(coll_price)
        new_feed_price = system['price_feed'].fetch_price()
        assert coll_price == new_feed_price

        with pytest.raises(Exception): 
            system['trove_manager'].liquidate(alice.address)

        #liquidate
        system['trove_manager'].liquidate(charlie.address)
