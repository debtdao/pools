# @version ^0.3.9

"""
@title 	Debt DAO Lending Pool Factory
@author Kiba Gateaux
"""

interface IERC20:
     def decimals() -> uint8: nonpayable
     def symbol() -> String[18]: nonpayable

interface IERC4626:
    def asset() -> address: nonpayable

event DeployPool:
    pool: indexed(address)
    delegate: indexed(address)
    token: indexed(address)

struct Fees: # from PoolDelegate.vy
	performance: uint16
	deposit: uint16
	withdraw: uint16
	flash: uint16
	collector: uint16
	referral: uint16

# default Debt DAO Pool init config
DEFAULT_FLASH_FEE: constant(uint16) = 5     # 5 bps. 0.05% per flashloan. Similar Aave rate.
DEFAULT_REFERRAL_FEE: constant(uint16) = 20 # 20 bps, 0.2% of deposit goes to incentivizing chicken bond liquidity

pool_implementation: public(immutable(address))

@external
def __init__(pool_impl: address):
    """
    @dev    MUST ensure `pool_imoplementation` was deployed properly.
            MUST follow instructions at https://github.com/vyperlang/vyper/blob/2adc34ffd3bee8b6dee90f552bbd9bb844509e19/tests/base_conftest.py#L130-L160
    @param pool_impl    Debt DAO Pool logic
    """
    pool_implementation = pool_impl

@external
def deploy_pool(_owner: address, _token: address, _name: String[50], _symbol: String[18],
                _performance_fee: uint16, _deposit_fee: uint16, _initial_deposit: uint256) -> address:

    fees: Fees = Fees({
        performance: _performance_fee,
        deposit: _deposit_fee,
        withdraw: 0,    # no penalty for withdrawals
        flash: DEFAULT_FLASH_FEE,       # passive income
        collector: 0,   # no automated collections
        referral: DEFAULT_REFERRAL_FEE, # bootstrap bond liquidity
    })

    # https://vyper.readthedocs.io/en/latest/built-in-functions.html?highlight=create_from_blueprint#create_from_blueprint
    pool: address = create_from_blueprint(
        pool_implementation,
        _owner, _token, _name, _symbol, fees, # args
        code_offset=0, # tbh dont know what this does
        salt=keccak256(_abi_encode(self, msg.sender, _token)) # similiar composite index as lines for pool CREATE2. (contract-actor-token)
    )

    log DeployPool(pool, _owner, _token)
    
### ALL CODE BELOW THIS POINT IS NON-ESSENTIAL FUNCTIONALITY TO DEBT DAO

    return pool

@internal
def _erc20_safe_transfer(token: address, receiver: address, amount: uint256):
    response: Bytes[32] = raw_call(
        token,
        concat(
            method_id("transfer(address,uint256)"),
            convert(receiver, bytes32),
            convert(amount, bytes32),
        ),
        max_outsize=32,
		revert_on_failure=True
    )

    if len(response) > 0:
        assert convert(response, bool), "Transfer failed!"