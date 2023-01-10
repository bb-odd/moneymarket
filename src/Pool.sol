// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/AggregatorV3Interface.sol";
import "forge-std/console.sol";

contract Pool is ERC20Burnable, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public totalDeposited;
    uint256 public totalBorrowed;
    uint256 public totalDebt;
    uint256 public totalReserve;
    uint256 public ltv; // 1 = 10%
    uint256 public multiplierPerTimestamp;
    uint256 public baseRatePerTimestamp;
    uint256 accrualBlockTimestamp;
    uint256 reserveFactor;
    address public immutable underlying;
    address public underlyingPriceFeed;
    uint256 public constant timestampsPerYear = 31536000;
    address constant ethPriceFeed = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    mapping(address => uint256) public usersCollateral;
    // this will store how much a user has borrowed not in underlying tokens but similar to how lenders receive pool tokens
    // underlying debt can be calculated using exchange rate and totalBorrowed
    mapping(address => uint256) public usersBorrowed;

    constructor(
        address _underlying,
        string memory _name,
        string memory _symbol,
        uint256 _ltv,
        address _aggregatorV3,
        uint256 _multiplierPerYear,
        uint256 _baseRatePerYear,
        uint256 _reserveFactor
    ) ERC20(_name, _symbol) {
        underlying = _underlying;
        ltv = _ltv;
        underlyingPriceFeed = _aggregatorV3;

        multiplierPerTimestamp =
            ((_multiplierPerYear * 1e18) / timestampsPerYear) /
            1e18;

        baseRatePerTimestamp =
            ((_baseRatePerYear * 1e18) / timestampsPerYear) /
            1e18;

        accrualBlockTimestamp = block.timestamp;
        reserveFactor = _reserveFactor;
    }

    // ADMIN FUNCTIONS
    function setLTV(uint256 _ltv) external onlyOwner {
        ltv = _ltv;
    }

    // USER FUNCTIONS

    // updates totalDebt with interest accrued since last block this function was called
    function accrueInterest() public {
        // borrowRate = baseRate + (Utilization * multiplier)
        uint256 borrowRate = (
            getUtilizationRatio().mulDiv(multiplierPerTimestamp, 1e18)
        ) + baseRatePerTimestamp;

        uint256 currentBlockTimestamp = block.timestamp;
        uint256 accrualBlockTimestampPrior = accrualBlockTimestamp;

        uint256 borrowsPrior = totalBorrowed;
        uint256 reservesPrior = totalReserve;

        // time passed since last function call in seconds
        uint256 blockDelta = currentBlockTimestamp - accrualBlockTimestamp;

        uint256 totalBorrowsNew;
        uint256 totalReservesNew;
        /*
         * Calculate the interest accumulated into borrows and reserves and the new index:
         *  simpleInterestFactor = borrowRate * blockDelta
         *  interestAccumulated = simpleInterestFactor * totalBorrows
         *  totalBorrowsNew = interestAccumulated + totalBorrows
         *  totalReservesNew = interestAccumulated * reserveFactor + totalReserves
         *  borrowIndexNew = simpleInterestFactor * borrowIndex + borrowIndex
         */
        uint256 interestFactor = borrowRate * blockDelta;

        uint256 interestAccumulated = interestFactor.mulDiv(borrowsPrior, 1e18);

        totalBorrowsNew = interestAccumulated + borrowsPrior;
        totalReservesNew =
            (interestAccumulated.mulDiv(reserveFactor, 1e18)) +
            reservesPrior;

        totalBorrowed = totalBorrowsNew;
        totalReserve = totalReservesNew;
    }

    function supply(uint256 _amount) external {
        accrueInterest();

        IERC20(underlying).safeTransferFrom(msg.sender, address(this), _amount);
        totalDeposited += _amount;

        uint256 tokensToMint = _amount.mulDiv(
            10 ** decimals(),
            getLendExchangeRate()
        );

        _mint(msg.sender, tokensToMint);
    }

    function redeem(uint256 _amount) external {
        accrueInterest();

        uint256 underlyingToReceive = _amount.mulDiv(
            getLendExchangeRate(),
            10 ** decimals()
        );
        totalDeposited -= underlyingToReceive;

        burn(_amount);
        IERC20(underlying).safeTransfer(msg.sender, underlyingToReceive);
    }

    function addCollateral() external payable nonReentrant {
        require(msg.value != 0, "can't send 0 eth");
        accrueInterest();

        usersCollateral[msg.sender] += msg.value;
    }

    // remember that we need to use debtExchangeRate when checking liquidity as the borrows need to be converted to underlying debt that includes accrued interest

    function removeCollateral(uint256 _amount) external nonReentrant {
        require(_amount != 0, "can't withdraw 0 eth");
        require(_amount <= usersCollateral[msg.sender]);
        accrueInterest();
        (uint256 excess, uint256 shortfall) = getLiquidity(msg.sender);

        uint ethPrice = getEthPrice();

        if (usersBorrowed[msg.sender] > 0) {
            require(
                excess >= _amount.mulDiv(uint(ethPrice), 10 ** 18),
                "not enough collateral available!"
            );
        }

        usersCollateral[msg.sender] -= _amount;
        (bool success, ) = (msg.sender).call{value: _amount}("");
        require(success, "eth transfer failed");
    }

    function borrow(uint256 _amount) external nonReentrant {
        require(_amount != 0, "can't borrow 0 tokens");
        (uint256 excess, uint256 shortfall) = getLiquidity(msg.sender);

        uint underlyingPrice = getUnderlyingPrice();

        require(
            excess >= _amount.mulDiv(uint(underlyingPrice), 10 ** decimals()),
            "not enough collateral available!"
        );

        uint256 borrowedTokens = _amount.mulDiv(
            getDebtExchangeRate(),
            10 ** decimals()
        );

        usersBorrowed[msg.sender] += borrowedTokens;
        totalBorrowed += borrowedTokens;
        totalDebt += _amount;

        IERC20 token = IERC20(underlying);
        token.safeTransfer(msg.sender, _amount);
    }

    function repay(uint256 _amount) external nonReentrant {
        require(_amount != 0, "can't repay 0 tokens!");
        uint256 borrowToRepay = _amount.mulDiv(
            getDebtExchangeRate(),
            10 ** decimals()
        );
        require(
            borrowToRepay <= usersBorrowed[msg.sender],
            "can't repay more than owed debt!"
        );

        IERC20 token = IERC20(underlying);
        token.safeTransferFrom(msg.sender, address(this), _amount);

        usersBorrowed[msg.sender] -= borrowToRepay;
        totalBorrowed -= borrowToRepay;
        totalDebt -= _amount;
    }

    // return excess and shortfall in usd terms
    // at least one of excess or shortfall will be 0
    function getLiquidity(
        address _account
    ) public view returns (uint256, uint256) {
        uint ethPrice = getEthPrice();
        uint underlyingPrice = getUnderlyingPrice();

        uint256 debtUsd = (
            usersBorrowed[_account].mulDiv(
                10 ** decimals(),
                getDebtExchangeRate()
            )
        ).mulDiv(underlyingPrice, 10 ** decimals());

        uint256 collateralUsd = (usersCollateral[_account].mulDiv(ltv, 10))
            .mulDiv(ethPrice, 10 ** 18);

        uint256 excess = 0;
        uint256 shortfall = 0;

        if (collateralUsd >= debtUsd) {
            excess = collateralUsd - debtUsd;
        } else {
            shortfall = debtUsd - collateralUsd;
        }
        return (excess, shortfall);
    }

    // exchangeRate = cash + totalBorrowed - reserve / totalSupply
    // we minus reserve as that is kept for the protocol governance
    function getLendExchangeRate() public view returns (uint256) {
        uint256 totalSupply_ = totalSupply();
        if (totalSupply_ == 0) {
            return 10 ** decimals();
        }

        return
            (getCash() + totalBorrowed - totalReserve).mulDiv(
                10 ** decimals(),
                totalSupply_
            );
    }

    // exchangeRate = totalBorrowed/ totalDebt (debt accrues interest while borrowed is the amount of "pool tokens" borrowed)
    function getDebtExchangeRate() public view returns (uint256) {
        uint256 _totalBorrowed = totalBorrowed;
        if (_totalBorrowed == 0) {
            return 10 ** decimals();
        }
        return _totalBorrowed.mulDiv(10 ** decimals(), totalDebt);
    }

    function getCash() public view returns (uint256) {
        IERC20 token = IERC20(underlying);
        return token.balanceOf(address(this));
    }

    function getUserCollat(address _account) public view returns (uint256) {
        return usersCollateral[_account];
    }

    function getUserBorrow(address _account) public view returns (uint256) {
        return usersBorrowed[_account];
    }

    function getUtilizationRatio() public view returns (uint256) {
        uint256 borrows = totalBorrowed;
        if (borrows == 0) {
            return 0;
        }

        // scale it to 1e18 no matter the decimals of underlying
        return
            ((totalBorrowed.mulDiv(10 ** decimals(), totalDeposited)) -
                totalReserve) * (10 ** (18 - decimals()));
    }

    // get underlying price scaled to 1e18
    function getUnderlyingPrice() internal view returns (uint) {
        AggregatorV3Interface UnderlyingPriceFeed = AggregatorV3Interface(
            underlyingPriceFeed
        );

        (, int256 underlyingPrice, , , ) = UnderlyingPriceFeed
            .latestRoundData();

        return
            uint256(underlyingPrice).mulDiv(
                10 ** decimals(),
                10 ** UnderlyingPriceFeed.decimals()
            );
    }

    // get eth price scaled to 1e18
    function getEthPrice() internal view returns (uint) {
        AggregatorV3Interface EthPriceFeed = AggregatorV3Interface(
            ethPriceFeed
        );

        (, int256 ethPrice, , , ) = EthPriceFeed.latestRoundData();

        return
            uint256(ethPrice).mulDiv(
                10 ** decimals(),
                10 ** EthPriceFeed.decimals()
            );
    }
}
