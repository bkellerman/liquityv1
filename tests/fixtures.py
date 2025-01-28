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
    boa.env.set_balance(accounts[1].address, 100* 10**18)
    return accounts[1]

@pytest.fixture
def bob(accounts):
    # 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
    boa.env.set_balance(accounts[2].address, 100* 10**18)
    return accounts[2]

@pytest.fixture
def charlie(accounts):
    # 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
    boa.env.set_balance(accounts[3].address, 100* 10**18)
    return accounts[3]

@pytest.fixture
def system_addresses(accounts):
    system_addresses = {'trove_manager': accounts[10].address,
                        'stability_pool': accounts[11].address,
                        'borrower_operations': accounts[12].address,
                        'active_pool': accounts[13].address,
                        'sorted_troves': accounts[14].address,
                        'price_feed': accounts[15].address,
                        'community_issuance': accounts[16].address,
                        'lusd_token': accounts[17].address,
                        'coll_surplus_pool': accounts[18].address,
                        'lqty_staking': accounts[19].address,
                        'default_pool': accounts[20].address,
                        'gas_pool': accounts[21].address,
                        'lqty_token': accounts[22].address,
                        'multisig': accounts[23].address,
                        'lockup_factory': accounts[24].address,
                        'bounty': accounts[25].address,
                        'lp_rewards': accounts[26].address,
                        'multisig': accounts[27].address,
                        'price_aggregator': accounts[28].address,
                        'tellor_caller': accounts[29].address
                        }
    return system_addresses

@pytest.fixture
def system(owner, alice, bob, system_addresses, project):
    stability_pool = boa.load_partial('contracts/stability_pool.vy').\
            deploy(override_address=system_addresses['stability_pool'])

    trove_manager = boa.load_partial('contracts/trove_manager.vy').\
            deploy(override_address=system_addresses['trove_manager'])

    borrower_operations = boa.load_partial('contracts/borrower_operations.vy').\
            deploy(override_address=system_addresses['borrower_operations'])

    active_pool = boa.load_partial('contracts/active_pool.vy').\
            deploy(override_address=system_addresses['active_pool'])

    sorted_troves = boa.load_partial('contracts/sorted_troves.vy').\
            deploy(override_address=system_addresses['sorted_troves'])

    price_feed = boa.load_partial('contracts/price_feed.vy').\
            deploy(override_address=system_addresses['price_feed'])

    coll_surplus_pool = boa.load_partial('contracts/coll_surplus_pool.vy').\
            deploy(override_address=system_addresses['coll_surplus_pool'])

    community_issuance = boa.load_partial('contracts/community_issuance.vy').\
            deploy(override_address=system_addresses['community_issuance'])

    lqty_staking = boa.load_partial('contracts/lqty_staking.vy').\
            deploy(override_address=system_addresses['lqty_staking'])

    lqty_token = boa.load_partial('contracts/lqty_token.vy').\
            deploy(system_addresses['community_issuance'],
                   system_addresses['lqty_staking'],
                   system_addresses['lockup_factory'],
                   system_addresses['bounty'],
                   system_addresses['lp_rewards'],
                   system_addresses['multisig'],
                   override_address=system_addresses['lqty_token'])

    default_pool = boa.load_partial('contracts/default_pool.vy').\
            deploy(override_address=system_addresses['default_pool'])

    # blank contract
    gas_pool = boa.load_partial('tests/contract.vy').\
            deploy(override_address=system_addresses['gas_pool'])

    # blank contract for now
    tellor_caller = boa.load_partial('tests/contract.vy').\
            deploy(override_address=system_addresses['tellor_caller'])

    price_aggregator = boa.load_partial('tests/chainlink.vy').\
            deploy(18, 1, "eth/usd feed", boa.env.evm.patch.timestamp, 2900 * 10**18,
                   override_address=system_addresses['price_aggregator'])

    lusd_token = boa.load_partial('contracts/lusd_token.vy').\
            deploy(system_addresses['trove_manager'],
            system_addresses['stability_pool'],
            system_addresses['borrower_operations'],
            override_address=system_addresses['lusd_token'])

    # setup stability pool
    stability_pool.set_addresses(system_addresses['borrower_operations'], system_addresses['trove_manager'],
        system_addresses['active_pool'], system_addresses['lusd_token'],
        system_addresses['sorted_troves'], system_addresses['price_feed'],
        system_addresses['community_issuance'])

    # setup borrower operations
    borrower_operations.set_addresses(system_addresses['trove_manager'], system_addresses['active_pool'],
                                    system_addresses['default_pool'],  system_addresses['stability_pool'],
                                    system_addresses['gas_pool'],  system_addresses['coll_surplus_pool'],
                                    system_addresses['price_feed'], system_addresses['sorted_troves'],
                                    system_addresses['lusd_token'], system_addresses['lqty_staking'])

    # setup trove manager
    trove_manager.set_addresses(system_addresses['borrower_operations'], system_addresses['active_pool'],
                                system_addresses['default_pool'],  system_addresses['stability_pool'],
                                system_addresses['gas_pool'],  system_addresses['coll_surplus_pool'],
                                system_addresses['price_feed'], system_addresses['lusd_token'],
                                system_addresses['sorted_troves'], system_addresses['lqty_token'],
                                system_addresses['lqty_staking'])

    # setup default pool
    default_pool.set_addresses(system_addresses['trove_manager'], system_addresses['active_pool'])

    # setup active pool
    active_pool.set_addresses(system_addresses['borrower_operations'], system_addresses['trove_manager'],
                                system_addresses['stability_pool'], system_addresses['default_pool'])

    # setup coll surplus pool
    coll_surplus_pool.set_addresses(system_addresses['borrower_operations'], system_addresses['trove_manager'],
                                    system_addresses['active_pool'])
    # setup sorted troves
    sorted_troves.set_params(1000, system_addresses['trove_manager'], system_addresses['borrower_operations'])

    # setup price feed
    price_feed.set_addresses(system_addresses['price_aggregator'], system_addresses['tellor_caller'])

    # setup community issuance
    community_issuance.set_addresses(system_addresses['lqty_token'], system_addresses['stability_pool'])

    # setup lqty staking
    lqty_staking.set_addresses(system_addresses['lqty_token'], system_addresses['lusd_token'],
                              system_addresses['trove_manager'], system_addresses['borrower_operations'],
                              system_addresses['active_pool'])
    # mint lusd
    boa.env.eoa = system_addresses['borrower_operations']
    lusd_token.mint(alice.address, int(1000000e18))
    lusd_token.mint(bob.address, int(2000000e18))
    boa.env.eoa = owner.address

    return {'lusd_token': lusd_token, 
            'stability_pool': stability_pool,
            'borrower_operations': borrower_operations,
            'trove_manager': trove_manager,
            'active_pool': active_pool,
            'sorted_troves': sorted_troves,
            'price_feed': price_feed,
            'coll_surplus_pool': coll_surplus_pool,
            'community_issuance': community_issuance,
            'lqty_staking': lqty_staking,
            'lqty_token': lqty_token,
            'default_pool': default_pool,
            'gas_pool': gas_pool,
            'price_aggregator': price_aggregator,
            'tellor_caller': tellor_caller
            }

@pytest.fixture
def frontend(accounts):
    return accounts[30]
