import boa
from fixtures import system, owner

def test(): assert True

def test_boa():
    boa.env.eoa = owner
    assert True
