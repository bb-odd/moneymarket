// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract Pool is ERC20Burnable, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public totalDeposit;
    uint256 public totalBorrowed;
    uint256 public totalCollateral;
    uint256 public totalDebt;
    uint256 public totalReserve;
    uint256 public ltv;
    address public immutable underlying;
    mapping(address => uint256) usersCollateral;
    // this will store how much a user has borrowed not in underlying tokens but similar to how lenders receive pool tokens
    // underlying debt can be calculated using exchange rate and totalBorrowed
    mapping(address => uint256) usersBorrowed;

    constructor(
        address _underlying,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        underlying = _underlying;
    }

    // exchangeRate = cash + totalBorrowed - reserve / totalSupply
    // we minus reserve as that is kept for the protocol governance
    function getLendExchangeRate() public returns(uint256){
        uint256 totalSupply = _totalSupply;
        if(totalSupply == 0){
            return 10**18;
        }

        return (getCash() + totalBorrowed - totalReserve).mulDiv(10**18,totalSupply());
    }

    // exchangeRate = totalBorrowed / totalDebt (debt accrues interest while borrowed is the amount of "pool tokens" borrowed)
    function getDebtExchangeRate() public returns(uint256){
        return totalDebt.mulDiv(10**18, totalBorrowed);
    }

    function getCash() public view returns(uint256){
        IERC20 token = IERC20(underlying);
        return token.balanceOf(address(this));
    } 

    function supply(uint256 _amount) external {
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), _amount);
        totalDeposit += _amount;
        uint256 tokensToMint = _amount / getExchangeRate(); 
        _mint(msg.sender, _amount);
    }

    function redeem(uint256 _amount) external {
        require(_amount <= balanceOf(msg.sender), "Not enough tokens");
        uint256 underlyingToReceive;
    }

    function addCollateral() external payable {}

    function removeCollateral() external {}

    function borrow() external {}

    function repay() external {}

    function getUtilizationRatio() public view returns(uint256){
        return total
    }
}
