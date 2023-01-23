# Logs
### Most important Tips
1. logs get overwritten after each function invocation. Must run all 


import boa
admin = boa.env.generate_address()
asset = boa.load('examples/ERC20.vy', 'An Asset To Lend', 'LEND', 18, 0)
asset.mint(admin, 200)
event = asset.get_logs()[0]
event.args_map



from py-evm 
- https://py-evm.readthedocs.io/en/latest/api/api.abc.html#eth.abc.ComputationAPI.get_log_entries
- https://github.com/ethereum/py-evm/blob/2da165f98cedf08d3a8d21ee92f9de82d0a1baa8/eth/vm/computation.py#L431-L441

"They are sorted in the same order they were emitted during the transaction processing, and include the sequential counter as the first element of the tuple representing every entry."

from boa:
- https://github.com/vyperlang/titanoboa/blob/1e73ba228f529e6988d165d440e580b98bdbcaed/boa/vyper/event.py#L5-L34


Data format from py-evm.get_raw_log_entries():
Tuple(
    'event log index',
    'event log index',
    'event topic',
    Tuple(event data),

)

Data format from boa.get_logs():

{
    'event topic',
    Tuple(event data),
}

