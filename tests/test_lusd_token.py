import ape
import pytest
import boa

@pytest.fixture
def owner(accounts):
    # 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
    return accounts[0]

@pytest.fixture
def alice(accounts):
    # 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
    return accounts[1]

@pytest.fixture
def bob(accounts):
    # 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
    return accounts[2]

@pytest.fixture
def trove_manager(accounts):
    return boa.load('tests/contract.vy')

@pytest.fixture
def stability_pool(accounts):
    return boa.load('tests/contract.vy')

@pytest.fixture
def borrower_operations(accounts):
    return boa.load('tests/contract.vy')

@pytest.fixture
def token(owner, alice, bob, trove_manager, stability_pool, borrower_operations,project):
    token = boa.load('contracts/lusd_token.vy',
            trove_manager.address,
            stability_pool.address,
            borrower_operations.address)

    boa.env.eoa = borrower_operations.address
    token.mint(alice.address, int(1e18))
    token.mint(bob.address, int(2e18))
    boa.env.eoa = owner.address

    return token

class TestRDToken:
    def test_mint(self, owner, alice, trove_manager, stability_pool, borrower_operations, token):
        with pytest.raises(Exception) as e_info:
            token.mint(alice.address, int(1e18))

        boa.env.eoa = trove_manager.address
        with pytest.raises(Exception) as e_info:
            token.mint(alice.address, int(1e18))

        boa.env.eoa = stability_pool.address
        with pytest.raises(Exception) as e_info:
            token.mint(alice.address, int(1e18))

        boa.env.eoa = borrower_operations.address
        token.mint(alice.address, int(1e18))

        assert token.balanceOf(alice) == int(2e18)

        token.mint(alice.address, int(1e18))

        assert token.balanceOf(alice) == int(3e18)

    def test_mint_zero_address(self, alice, trove_manager, stability_pool, borrower_operations, token):
        boa.env.eoa = borrower_operations.address
        with pytest.raises(Exception) as e_info:
            token.mint(address(0), int(1e18))

    def test_burn(self, alice, trove_manager, stability_pool, borrower_operations, token):
        boa.env.eoa = borrower_operations.address
        # revert when burning more than balance
        with pytest.raises(Exception) as e_info:
            token.burn(alice, int(2e18))
        
        #borrower ops burn
        token.mint(alice.address, int(1e18))
        token.burn(alice, int(1e18))
        assert token.balanceOf(alice) == int(1e18)
    
        # trove manager burn
        token.mint(alice.address, int(1e18))
        boa.env.eoa = trove_manager.address
        token.burn(alice, int(1e18))
        assert token.balanceOf(alice) == int(1e18)

        # stability pool burn
        boa.env.eoa = borrower_operations.address
        token.mint(alice.address, int(1e18))
        boa.env.eoa = stability_pool.address
        token.burn(alice, int(1e18))
        assert token.balanceOf(alice) == int(1e18)

    def test_transfer_from(self, alice, bob, trove_manager, stability_pool, borrower_operations, token):
        boa.env.eoa = alice.address

        # should fail with zero allowance
        with pytest.raises(Exception) as e_info:
            token.transferFrom(alice, bob, int(1e17))

        token.increase_allowance(alice, int(1e17))

        token.transferFrom(alice, bob, int(1e17))

        assert token.balanceOf(alice) == int(9e17)

