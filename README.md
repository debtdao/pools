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
$ >>>>> boa.interpret.set_cache_dir()  # cache source compilations across sessions
$ >>>>> admin = boa.env.generate_address()
$ >>>>> asset = boa.load('tests/mocks/MockERC20.vy', 'An Asset To Lend', 'LEND', 18)
$ >>>>> pool = boa.load('contracts/DebtDAOPool.vy', admin, asset, 'Dev Testing', 'TEST', [0,0,0,0,0,0])
$ >>>>> asset.decimals()
$ >>>>> pool.decimals()
$ >>>>> pool.eval('INSOLVENT_STATUS') == 4
```

## Testing
`ape test --network=::foundry --cache-clear -v INFO`

# Docs
install Mermaid CLI
`https://github.com/mermaid-js/mermaid-cli`

`mmdc -i ./docs/ChikkinPonziSystem.mmd -o ./docs/ChikkinPonziSystem.svg -t dark -b transparent && open ./docs/ChikkinPonziSystem.png `