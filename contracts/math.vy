# SPDX-License-Identifier: MIT
# pragma version ~=0.4.0

DECIMAL_PRECISION: constant(uint256) = 10 ** 18
NICR_PRECISION: constant(uint256) = 10 ** 20

@internal
@pure
def _min(a: uint256, b: uint256) -> uint256:
    return a if a < b else b

@internal
@pure
def _max(a: uint256, b: uint256) -> uint256:
    return a if a >= b else b

@internal
@pure
def _dec_mul(x: uint256, y: uint256) -> uint256:
    prod_xy: uint256 = x * y
    return (prod_xy + DECIMAL_PRECISION // 2) // DECIMAL_PRECISION

@internal
@pure
def _dec_pow(base: uint256, minutes: uint256) -> uint256:
    if minutes > 525600000:
        minutes = 525600000

    if minutes == 0:
        return DECIMAL_PRECISION

    y: uint256 = DECIMAL_PRECISION
    x: uint256 = base
    n: uint256 = minutes


    for _: uint96 in range(256):
        if n == 0:
            break

        if n % 2 == 0:
            x = self._dec_mul(x, x)
            n //= 2
        else:
            y = self._dec_mul(x, y)
            x = self._dec_mul(x, x)
            n = (n - 1) // 2

    return self._dec_mul(x, y)

@internal
@pure
def _get_absolute_difference(a: uint256, b: uint256) -> uint256:
    return a - b if a >= b else b - a

@internal
@pure
def _compute_nominal_cr(coll: uint256, debt: uint256) -> uint256:
    if debt > 0:
        return coll * NICR_PRECISION // debt
    else:
        return max_value(uint256)

@internal
@pure
def _compute_cr(coll: uint256, debt: uint256, price: uint256) -> uint256:
    if debt > 0:
        return coll * price // debt
    else:
        return max_value(uint256)
