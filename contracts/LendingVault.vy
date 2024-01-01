# @version 0.3.10
"""
@title ERC4626+ Vault for lending with crvUSD using LLAMMA algorithm
@author Curve.Fi
@license Copyright (c) Curve.Fi, 2020-2024 - all rights reserved
"""

interface ERC20:
    def transferFrom(_from: address, _to: address, _value: uint256) -> bool: nonpayable
    def transfer(_to: address, _value: uint256) -> bool: nonpayable
    def decimals() -> uint8: view
    def balanceOf(_from: address) -> uint256: view
    def symbol() -> String[32]: view
    def name() -> String[64]: view

interface AMM:
    def set_admin(_admin: address): nonpayable

interface Controller:
    def total_debt() -> uint256: view
    def minted() -> uint256: view
    def redeemed() -> uint256: view

interface PriceOracle:
    def price() -> uint256: view
    def price_w() -> uint256: nonpayable

interface MonetaryPolicy:
    def rate_write() -> uint256: nonpayable


# ERC20 events

event Approval:
    owner: indexed(address)
    spender: indexed(address)
    value: uint256

event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    value: uint256

# ERC4626 events

event Deposit:
    sender: indexed(address)
    owner: indexed(address)
    assets: uint256
    shares: uint256

event Withdraw:
    sender: indexed(address)
    receiver: indexed(address)
    owner: indexed(address)
    assets: uint256
    shares: uint256


# Limits
MIN_A: constant(uint256) = 2
MAX_A: constant(uint256) = 10000
MIN_FEE: constant(uint256) = 10**6  # 1e-12, still needs to be above 0
MAX_FEE: constant(uint256) = 10**17  # 10%
MAX_ADMIN_FEE: constant(uint256) = 10**18  # 100%
MAX_LOAN_DISCOUNT: constant(uint256) = 5 * 10**17
MIN_LIQUIDATION_DISCOUNT: constant(uint256) = 10**16

STABLECOIN: public(immutable(ERC20))

borrowed_token: public(ERC20)
collateral_token: public(ERC20)

monetary_policy: public(address)
price_oracle_contract: public(address)

amm: public(AMM)
controller: public(Controller)


# ERC20 publics

decimals: public(uint8)
name: public(String[64])
symbol: public(String[32])

NAME_PREFIX: constant(String[16]) = 'Curve Vault for '
SYMBOL_PREFIX: constant(String[2]) = 'cv'

allowance: public(HashMap[address, HashMap[address, uint256]])
balanceOf: public(HashMap[address, uint256])
totalSupply: public(uint256)


@external
def __init__(stablecoin: ERC20):
    # The contract is made a "normal" template (not blueprint) so that we can get contract address before init
    # This is needed if we want to create a rehypothecation dual-market with two vaults
    # where vaults are collaterals of each other
    self.borrowed_token = ERC20(0x0000000000000000000000000000000000000001)
    STABLECOIN = stablecoin


@internal
@pure
def ln_int(_x: uint256) -> int256:
    """
    @notice Logarithm ln() function based on log2. Not very gas-efficient but brief
    """
    # adapted from: https://medium.com/coinmonks/9aef8515136e
    # and vyper log implementation
    # This can be much more optimal but that's not important here
    x: uint256 = _x
    res: uint256 = 0
    for i in range(8):
        t: uint256 = 2**(7 - i)
        p: uint256 = 2**t
        if x >= p * 10**18:
            x /= p
            res += t * 10**18
    d: uint256 = 10**18
    for i in range(59):  # 18 decimals: math.log2(10**10) == 59.7
        if (x >= 2 * 10**18):
            res += d
            x /= 2
        x = x * x / 10**18
        d /= 2
    # Now res = log2(x)
    # ln(x) = log2(x) / log2(e)
    return convert(res * 10**18 / 1442695040888963328, int256)


@external
def initialize(
        amm_impl: address,
        controller_impl: address,
        borrowed_token: ERC20,
        collateral_token: ERC20,
        A: uint256,
        fee: uint256,
        admin_fee: uint256,
        price_oracle_contract: address,  # Factory makes from template if needed, deploying with a from_pool()
        monetary_policy: address,  # Standard monetary policy set in factory
        loan_discount: uint256,
        liquidation_discount: uint256
    ) -> address[2]:
    assert self.borrowed_token.address == empty(address)
    assert STABLECOIN == borrowed_token or STABLECOIN == collateral_token

    self.borrowed_token = borrowed_token
    self.collateral_token = collateral_token
    self.monetary_policy = monetary_policy
    self.price_oracle_contract = price_oracle_contract

    assert A >= MIN_A and A <= MAX_A, "Wrong A"
    assert fee <= MAX_FEE, "Fee too high"
    assert fee >= MIN_FEE, "Fee too low"
    assert admin_fee < MAX_ADMIN_FEE, "Admin fee too high"
    assert liquidation_discount >= MIN_LIQUIDATION_DISCOUNT, "Liquidation discount too low"
    assert loan_discount <= MAX_LOAN_DISCOUNT, "Loan discount too high"
    assert loan_discount > liquidation_discount, "need loan_discount>liquidation_discount"
    MonetaryPolicy(monetary_policy).rate_write()  # Test that MonetaryPolicy has correct ABI

    p: uint256 = PriceOracle(price_oracle_contract).price()  # This also validates price oracle ABI
    assert p > 0
    assert PriceOracle(price_oracle_contract).price_w() == p
    A_ratio: uint256 = 10**18 * A / (A - 1)

    amm: address = create_from_blueprint(
        amm_impl,
        borrowed_token.address, 10**(18 - borrowed_token.decimals()),
        collateral_token.address, 10**(18 - collateral_token.decimals()),
        A, isqrt(A_ratio * 10**18), self.ln_int(A_ratio),
        p, fee, admin_fee, price_oracle_contract,
        code_offset=3)
    controller: address = create_from_blueprint(
        controller_impl,
        empty(address), monetary_policy, loan_discount, liquidation_discount, amm,
        code_offset=3)
    AMM(amm).set_admin(controller)

    self.amm = AMM(amm)
    self.controller = Controller(controller)

    # ERC20 set up
    self.decimals = borrowed_token.decimals()
    borrowed_symbol: String[32] = borrowed_token.symbol()
    self.name = concat(NAME_PREFIX, borrowed_symbol)
    self.symbol = concat(SYMBOL_PREFIX, slice(borrowed_symbol, 0, 30))

    # No events because it's the only market we would ever create in this contract

    return [controller, amm]


@external
@view
def asset() -> ERC20:
    """
    Method returning borrowed asset address for ERC4626 compatibility
    """
    return self.borrowed_token


@internal
@view
def _total_assets() -> uint256:
    # admin fee should be accounted for here when enabled
    return self.borrowed_token.balanceOf(self.controller.address) + self.controller.total_debt()


@external
@view
def totalAssets() -> uint256:
    return self._total_assets()


@external
@view
def pricePerShare() -> uint256:
    supply: uint256 = self.totalSupply
    if supply == 0:
        return 10**18
    else:
        return self._total_assets() / supply


@external
def deposit(assets: uint256, receiver: address = msg.sender) -> uint256:
    to_mint: uint256 = assets * self.totalSupply / self._total_assets()
    assert self.borrowed_token.transferFrom(msg.sender, self.controller.address, assets, default_return_value=True)
    self._mint(receiver, to_mint)
    log Deposit(msg.sender, receiver, assets, to_mint)
    return to_mint


# ERC20 methods

@internal
def _approve(_owner: address, _spender: address, _value: uint256):
    self.allowance[_owner][_spender] = _value

    log Approval(_owner, _spender, _value)


@internal
def _burn(_from: address, _value: uint256):
    self.balanceOf[_from] -= _value
    self.totalSupply -= _value

    log Transfer(_from, empty(address), _value)


@internal
def _mint(_to: address, _value: uint256):
    self.balanceOf[_to] += _value
    self.totalSupply += _value

    log Transfer(empty(address), _to, _value)


@internal
def _transfer(_from: address, _to: address, _value: uint256):
    assert _to not in [self, empty(address)]

    self.balanceOf[_from] -= _value
    self.balanceOf[_to] += _value

    log Transfer(_from, _to, _value)


@external
def transferFrom(_from: address, _to: address, _value: uint256) -> bool:
    """
    @notice Transfer tokens from one account to another.
    @dev The caller needs to have an allowance from account `_from` greater than or
        equal to the value being transferred. An allowance equal to the uint256 type's
        maximum, is considered infinite and does not decrease.
    @param _from The account which tokens will be spent from.
    @param _to The account which tokens will be sent to.
    @param _value The amount of tokens to be transferred.
    """
    allowance: uint256 = self.allowance[_from][msg.sender]
    if allowance != max_value(uint256):
        self._approve(_from, msg.sender, allowance - _value)

    self._transfer(_from, _to, _value)
    return True


@external
def transfer(_to: address, _value: uint256) -> bool:
    """
    @notice Transfer tokens to `_to`.
    @param _to The account to transfer tokens to.
    @param _value The amount of tokens to transfer.
    """
    self._transfer(msg.sender, _to, _value)
    return True


@external
def approve(_spender: address, _value: uint256) -> bool:
    """
    @notice Allow `_spender` to transfer up to `_value` amount of tokens from the caller's account.
    @dev Non-zero to non-zero approvals are allowed, but should be used cautiously. The methods
        increaseAllowance + decreaseAllowance are available to prevent any front-running that
        may occur.
    @param _spender The account permitted to spend up to `_value` amount of caller's funds.
    @param _value The amount of tokens `_spender` is allowed to spend.
    """
    self._approve(msg.sender, _spender, _value)
    return True


@external
def increaseAllowance(_spender: address, _add_value: uint256) -> bool:
    """
    @notice Increase the allowance granted to `_spender`.
    @dev This function will never overflow, and instead will bound
        allowance to MAX_UINT256. This has the potential to grant an
        infinite approval.
    @param _spender The account to increase the allowance of.
    @param _add_value The amount to increase the allowance by.
    """
    cached_allowance: uint256 = self.allowance[msg.sender][_spender]
    allowance: uint256 = unsafe_add(cached_allowance, _add_value)

    # check for an overflow
    if allowance < cached_allowance:
        allowance = max_value(uint256)

    if allowance != cached_allowance:
        self._approve(msg.sender, _spender, allowance)

    return True


@external
def decreaseAllowance(_spender: address, _sub_value: uint256) -> bool:
    """
    @notice Decrease the allowance granted to `_spender`.
    @dev This function will never underflow, and instead will bound
        allowance to 0.
    @param _spender The account to decrease the allowance of.
    @param _sub_value The amount to decrease the allowance by.
    """
    cached_allowance: uint256 = self.allowance[msg.sender][_spender]
    allowance: uint256 = unsafe_sub(cached_allowance, _sub_value)

    # check for an underflow
    if cached_allowance < allowance:
        allowance = 0

    if allowance != cached_allowance:
        self._approve(msg.sender, _spender, allowance)

    return True
