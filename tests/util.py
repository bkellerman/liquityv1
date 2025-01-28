import boa

ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'


def set_sender(account):
    boa.env.eoa = account.address

def reset_sender():
    boa.env.eoa = owner.address

def print_addresses(system):
    for k, v in system.items():
        print(f"{k}: {v.address}")
