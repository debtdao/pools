TODO:
- copy project structure of https://github.com/curvefi/curve-stablecoin with boa testing
- https://curve.readthedocs.io/guide-code-style.html


## Installation

```bash
 pip install -r ape-requirements.txt   
 pip install -r boa-requirements.txt   
ape plugins install .
```

## Development
To get a feel for the contracts you should start plalying around with them in boa.

```
$ [insert your pythong virtual environment command here]

$ python

$ >>>>> import boa
# cache source compilations across sessions
$ >>>>> boa.interpret.set_cache_dir()
# allow gas profiling e.g. pool.line_profile().summary()
$ >>>>> boa.env.enable_gas_profiling()
$ >>>>> admin = boa.env.generate_address()
$ >>>>> asset = boa.load('tests/mocks/MockERC20.vy', 'An Asset To Lend', 'LEND', 18)
$ >>>>> pool = boa.load('contracts/DebtDAOPool.vy', admin, asset, 'Dev Testing', 'TEST', [0,0,0,0,0,0])
$ >>>>> asset.decimals()
$ >>>>> pool.decimals()
$ >>>>> mint_amount = 100
$ >>>>> asset._mint_for_testing(admin, mint_amount, sender=admin)
$ >>>>> asset.approve(pool, mint_amount, sender=admin)
$ >>>>> pool.deposit(mint_amount, admin, sender=admin)
$ >>>>> pool.line_profile().summary()
```

### Boa dev notes
1. dont overwrite variables in the repl.
This sequenece of commands will fail because the `asset` you are minting and approving to is different han the `asset` in the Pool contract.
```
$ >>>>> asset = boa.load('tests/mocks/MockERC20.vy', 'An Asset To Lend', 'LEND', 18)
$ >>>>> pool = boa.load('contracts/DebtDAOPool.vy', admin, asset, 'Dev Testing', 'TEST', [0,0,0,0,0,0])
$ >>>>> asset = boa.load('tests/mocks/MockERC20.vy', 'An Asset To Lend', 'LEND', 18)
$ >>>>> asset._mint_for_testing(admin, mint_amount, sender=admin)
$ >>>>> asset.approve(pool, mint_amount, sender=admin)
$ >>>>> pool.deposit(mint_amount, admin, sender=admin)
```
2. Must redeploy contracts with `boa.load` for code changes to take affect

## Testing
`ape test --network=::foundry --cache-clear -v INFO`

# Docs
install Mermaid CLI
`https://github.com/mermaid-js/mermaid-cli`

`mmdc -i ./docs/ChikkinPonziSystem.mmd -o ./docs/ChikkinPonziSystem.svg -t dark -b transparent && open ./docs/ChikkinPonziSystem.png `