// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Pool.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PoolTest is Test {
    Pool public pool;
    address constant binance = 0xF977814e90dA44bFA03b6295A0616a897441aceC;
    address constant dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    ERC20 daiToken;

    function setUp() public {
        pool = new Pool(
            dai,
            "Pool Dai",
            "pDai",
            4,
            0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9
        );
        daiToken = ERC20(dai);
    }

    function getDai(address _holder, uint256 _amount) public {
        vm.startPrank(_holder);
        daiToken.transferFrom(_holder, address(this), _amount);
        vm.stopPrank();
    }

    function testCheckOwner() public {
        assertEq(pool.owner(), address(this));
    }

    // test lending 1000 dai to pool test redeeming pool tokens to get initial dai lended back
    function testTokenLendRedeem() public {
        getDai(binance, 1000 * 10 ** 18);
        daiToken.approve(address(pool), type(uint256).max);
        pool.supply(1000 * 10 ** 18);
        assertEq(pool.balanceOf(address(this)), 1000 * 10 ** 18);

        pool.redeem(pool.balanceOf(address(this)));
        assertEq(daiToken.balanceOf(address(this)), 1000 * 10 ** 18);
    }

    function testAddRemoveCollateral() public {
        pool.addCollateral{value: 1 * 10 ** 18}();
        assertEq(1 * 10 ** 18, pool.getUserCollat(address(this)));
        assertEq(1 * 10 ** 18, address(pool).balance);

        uint256 balanceBefore = address(this).balance;
        pool.removeCollateral(1 * 10 ** 18);
        assertEq(1 * 10 ** 18, address(this).balance - balanceBefore);
    }

    // test get liquidity function

    // test revert of remove collateral function if amount to borrow exceeds liquidity of account

    // test revert can't pay more than owed debt

    // test exchange rates after users lend and borrow

    // test exchange rates after users lend and borrow and interest is accrued

    // test interest accrued ( 1 lender 1 borrower) (multiple lenders / borrowers)

    // test redeeming tokens after interest accrued ( 1 lender 1 borrower) (multiple lenders / borrowers)

    // test repaying debt after interest accrued ( 1 lender 1 borrower) (multiple lenders / borrowers)

    // test withdrawing collateral after repaying debt ( 1 lender 1 borrower) (multiple lenders / borrowers)

    // repeat these tests with tokens with different decimals

    // Function to receive Ether. msg.data must be empty
    receive() external payable {}

    // Fallback function is called when msg.data is not empty
    fallback() external payable {}
}
