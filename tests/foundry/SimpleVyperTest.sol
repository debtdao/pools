// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "forge-std/Test.sol";

import {VyperDeployer} from "./utils/VyperDeployer.sol";

interface IBondToken {
    function mint(address _target, uint256 _value)
        external
        returns (bool);

    function balanceOf(address _owner) external view returns (uint256);

    function name() external view returns (string memory);

    function decimals() external view returns (uint256);
}

contract SimpleVyperTest is Test {
    ///@notice create a new instance of VyperDeployer
    VyperDeployer vyperDeployer = new VyperDeployer();
    IBondToken iToken;

    address debtdao = makeAddr("debtdao");

    function setUp() public {
        ///@notice deploy a new instance of ISimplestore by passing in the address of the deployed Vyper contract
        iToken = IBondToken(
            vyperDeployer.deployContract(
                "tests/mocks/MockERC20",
                abi.encode(
                    "Vyper Token", // name
                    "VTK", // symbol
                    18 //decimals
                )
            )
        );
    }

    function test_can_mint_as_manager() public {
        address recipient = makeAddr("recipient");
        string memory name = iToken.name();
        uint256 decimals = iToken.decimals();
        emit log_named_uint("decimals", decimals);
        console.log(name);
        emit log_string(name);
        vm.startPrank(debtdao);
        iToken.mint(recipient, 100 ether);
        assertEq(iToken.balanceOf(recipient), 100 ether);
    }
}
