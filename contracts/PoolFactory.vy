# @version ^0.3.7

struct Fees: # from PoolDelegate.vy
	performance: uint16
	deposit: uint16
	withdraw: uint16
	flash: uint16
	collector: uint16
	referral: uint16

pool_implementation: public(immutable(address))

@external
def __init__(pool_impl: address):
    """
    @dev    MUST ensure `pool_imoplementation` was deployed properly.
            MUST follow instructions at https://github.com/vyperlang/vyper/blob/2adc34ffd3bee8b6dee90f552bbd9bb844509e19/tests/base_conftest.py#L130-L160
    """
    pool_implementation = pool_impl

@external
def deploy_pool(owner: address, token: address, name: String[50], symbol: String[18], fees: Fees) -> address:
    # https://vyper.readthedocs.io/en/latest/built-in-functions.html?highlight=create_from_blueprint#create_from_blueprint
    pool: address = create_from_blueprint(
        pool_implementation,
        owner,
        token,
        name,
        symbol,
        fees,
        code_offset=0, # tbh dont know what this does
        salt=keccak256(_abi_encode(self, msg.sender, token)) # similiar composite index as lines for pool CREATE2. (contract-actor-token)
    )

    # deploy chicken bond for new pool

    return pool

# fin




# much empty
# fuck around and throw some NFT shit in here?





