// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MoonRewards} from "../src/MoonRewards.sol";
import {MoonShop} from "../src/MoonShop.sol";

/// @dev Local deployment harness only; no script signs, broadcasts or calls the real factory.
contract DeploymentFixture {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "constructor failed");
    }
}

contract DeploymentCompatibilityTest is Test {
    LaunchToken internal token;
    MoonRewards internal rewards;
    MoonShop internal shop;
    DeploymentFixture internal factory;
    address internal owner;

    function setUp() public {
        vm.chainId(4663);
        owner = makeAddr("launch owner");
        factory = new DeploymentFixture();
        token = LaunchToken(factory.deploy(type(LaunchToken).creationCode, bytes32(uint256(1))));
        rewards = MoonRewards(
            factory.deploy(
                abi.encodePacked(type(MoonRewards).creationCode, abi.encode(address(token), owner)), bytes32(uint256(2))
            )
        );
        shop = MoonShop(
            factory.deploy(
                abi.encodePacked(type(MoonShop).creationCode, abi.encode(address(token), address(rewards), owner)),
                bytes32(uint256(3))
            )
        );
    }

    function test_factoryKeepsWholeSupplyAcrossAllConstructors() public view {
        assertEq(token.balanceOf(address(factory)), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(rewards)), 0);
        assertEq(token.balanceOf(address(shop)), 0);
        assertEq(rewards.owner(), owner);
        assertEq(shop.owner(), owner);
        assertEq(shop.creator(), owner);
        assertEq(address(shop.rewards()), address(rewards));
    }

    function test_noApplicationRequiresPostOfficeDuringConstruction() public view {
        assertEq(rewards.POST_OFFICE().code.length, 0);
        assertFalse(rewards.isFunded());
        assertEq(rewards.voucherSigner(), address(0));
    }

    function test_runtimeBoundedAndHasNoForbiddenOpcodes() public view {
        address[3] memory contracts_ = [address(token), address(rewards), address(shop)];
        for (uint256 i; i < contracts_.length; ++i) {
            bytes memory code = contracts_[i].code;
            assertGt(code.length, 0);
            assertLe(code.length, 24_576);
            for (uint256 j; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            }
        }
    }

    function test_contractsDoNotAcceptNativePaymentsOrRefundGas() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok);
        (ok,) = address(rewards).call{value: 1}("");
        assertFalse(ok);
        (ok,) = address(shop).call{value: 1}("");
        assertFalse(ok);
    }
}
