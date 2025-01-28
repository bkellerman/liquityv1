import ape
import pytest
import boa

from util import set_sender, reset_sender, ZERO_ADDRESS
from fixtures import system, owner, alice, bob, frontend, system_addresses

class TestStabilityPool:
    def test_initial(self, system):
        sp = system['stability_pool']
        assert sp.get_eth() == 0
        assert sp.get_total_lusd_deposits() == 0

    def test_provide_to_sp_zero_frontend(self, alice, system, frontend):
        sp = system['stability_pool']
        set_sender(alice)
        sp.provide_to_sp(10**18, ZERO_ADDRESS)

        assert sp.deposits(alice.address) == (10**18, ZERO_ADDRESS)
        assert sp.get_depositor_eth_gain(alice.address) == 0

    def test_provide_to_sp_registered_frontend(self, alice, system, frontend):
        sp = system['stability_pool']
        set_sender(frontend)
        sp.register_frontend(10**17)
        set_sender(alice)
        sp.provide_to_sp(10**18, frontend.address)

        assert sp.deposits(alice.address) == (10**18, frontend.address)
        assert sp.get_depositor_eth_gain(alice.address) == 0

    def test_register_frontend(self, system, frontend):
        sp = system['stability_pool']
        assert sp.frontends(frontend.address) == (0, False)
        set_sender(frontend)
        sp.register_frontend(10**17)

        assert sp.frontends(frontend.address) == (10**17, True)
