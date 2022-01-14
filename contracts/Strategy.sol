// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

// interfaces
import "../interfaces/IUniLikeSwapRouter.sol";
import "../interfaces/aave/ILendingPool.sol";
import "../interfaces/aave/ILendingPoolAddressesProvider.sol";
import "../interfaces/aave/IProtocolDataProvider.sol";
import "../interfaces/aave/IAaveIncentivesController.sol";
import "../interfaces/aave/IAToken.sol";
import "../interfaces/aave/IStakedAave.sol";
import "../interfaces/aave/IVariableDebtToken";


contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    //AAVE protocol address 
    IProtocolDataProvider private constant  protocolDataProvider = IProtocolDataProvider(0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d);
    IAaveIncentivesController private constant incentivesController = IAaveIncentivesController(0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5);
    ILendingPool private constant lendingPool = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);

    // predstalja stkAave cooldown status
    // 0 = no cooldown or past withdraw period
    // 1 = cooldown initiated, future claim period
    // 2 = claim period
    enum CooldownStatus {
        None,
        Initiated,
        Claim
    }

    //Token address
    address private constant aave = 0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9;
    IStakedAave private constant stkAave = IStakedAave(0x4da27a545c0c5b758a6ba100e3a049001de870f5);
    address private constant weth = 0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2;
    address private constant rewardToken = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;

    // Supply and borrow tokens
    IAToken public aToken;
    IVariableDebtToken public debtToken;

     // SWAP routers
    IUniLikeSwapRouter private PRIMARY_ROUTER = IUniLikeSwapRouter(0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff);
    IUniLikeSwapRouter private SECONDARY_ROUTER = IUniLikeSwapRouter(0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506);

    // State Variables
    uint256 public maxBorrowCollatRatio; // maximalna kolicina koju mozemo da pozajmimo na aave u tokenima
    uint256 public targetCollatRatio; // od koliko kolatereala krecemeo (LTV)? 
    uint256 public maxCollatRatio; // koliko smo blizu likvidacije ? da li mora da bude vece od 1? 

    uint8 public maxIterations; // mksimalan broj iteracija koji ima smisla da se napravi 
    
    uint256 public minWant; // minimalni broj tokena  want. da li postoji razlog zasto je ovo minilani broj tokena ? da li to moze da bude bilo koji broj ?
    uint256 public minRewardToSell; // minimalni iznos reward tokena da bi se prodali za want 

    bool private alreadyAdjusted = false; // dedfault value je false ? ne mora da se setuje onda false ?

    uint16 private constant referall = 0;

    constructor(address _vault) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
    }

    // da li bi ova funkcija initialize() mogla da se stavi iznad u constructor ? 
    // da li iz funkcije _initializeThis() moze da se stavi sve u constructor ? 
    // nisam sigura za ovo
    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper
    ) external override {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeThis();
    }

    // deodelis vrednosti varijablama 
    function _initializeThis() internal {
        require(address(aToken) == address(0));

        maxIterations = 10;
        minWant = 99;
        minRewardToSell = 1e15;
        
        // Set aave tokens
        (address _aToken, , address _debtToken) =
            protocolDataProvider.getReserveTokensAddresses(address(want));
        aToken = IAToken(_aToken);
        debtToken = IVariableDebtToken(_debtToken);

        // approve spend aave spend
        approveMaxSpend(address(want), address(lendingPool));
        approveMaxSpend(address(aToken), address(lendingPool));

        // approve swap router spend
        approveMaxSpend(rewardToken, address(PRIMARY_ROUTER));
        if (address(SECONDARY_ROUTER) != address(0)) {
            approveMaxSpend(rewardToken, address(SECONDARY_ROUTER));
        }
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        return "StrategyAAVE";
    }

    // ukupan iznos u want tokenima kojima strategija trenutno upravlja
    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 balanceExcludingRewards = balanceOfWant().add(balanceOfAToken());

        // ako nema otvorene pozicije, nema rewards
        if (balanceExcludingRewards < minWant) {
            return balanceExcludingRewards;
        }

        uint256 rewards = balanceOfRewardToken();
        
        return balanceExcludingRewards.add(rewards);
    }


    function prepareReturn(uint256 _debtOutstanding) internal override returns ( uint256 _profit, uint256 _loss, uint256 _debtPayment) {
        // Claim and sell rewards
        _claimAndSellRewards();

        // ukupno duggovanje prema vault-u
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;

        // Imovina koju posedujes
        uint256 supply = getCurrentSupply(); // sredstva koja smo deponovali - pozajmljena sredstva
        uint256 totalAssets = balanceOfWant().add(supply); // ukupna sredstva u strateggiji

        // PROVERA DA LI JE GUBITAK ILI DOBITAK
        if (totalDebt > totalAssets) {
            // gubitak
            _loss = totalDebt.sub(totalAssets);
        } else { 
            // dobitak
            _profit = totalAssets.sub(totalDebt);
        }
        // _debtOutstanding -> iznos koji mora da se da vault-u
        uint256 amountAvailable = balanceOfWant(); // dostupno tokena u strategiji
        uint256 amountRequired = _debtOutstanding.add(_profit); // ono sta dugujemo vaultu + profit koji mora da se vrati

        if (amountRequired > amountAvailable) {
            // vault trazi vise nego sto imamo tokena u strategiji
            // mora da se likvidira odredjena kolicina tokena iz AAVE
            (amountAvailable, ) = liquidatePosition(amountRequired); 

            alreadyAdjusted = true;

            if (amountAvailable >= amountRequired) {
                _debtPayment = _debtOutstanding;
                // profit remains unchanged unless there is not enough to pay it
                // nisam razumeo
                if (amountRequired.sub(_debtPayment) < _profit) {
                    _profit = amountRequired.sub(_debtPayment);
                }
            } else {
                // we were not able to free enough funds
                // ne mozemo da oslobodimo dovoljno sredstava
                if (amountAvailable < _debtOutstanding) {
                    // available funds are lower than the repayment that we need to do
                    _profit = 0;
                    _debtPayment = amountAvailable;
                    // we dont report losses here as the strategy might not be able to return in this harvest
                    // but it will still be there for the next harvest
                } else {
                    // NOTE: amountRequired is always equal or greater than _debtOutstanding
                    // important to use amountRequired just in case amountAvailable is > amountAvailable
                    _debtPayment = _debtOutstanding;
                    _profit = amountAvailable.sub(_debtPayment);
                }
            }
        } else {
            _debtPayment = _debtOutstanding;
            // profit remains unchanged unless there is not enough to pay it
            if (amountRequired.sub(_debtPayment) < _profit) {
                _profit = amountRequired.sub(_debtPayment);
            }
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // TODO: Do something to invest excess `want` tokens (from the Vault) into your positions
        // NOTE: Try to adjust positions so that `_debtOutstanding` can be freed up on *next* harvest (not immediately)
        if (alreadyAdjusted) {
            alreadyAdjusted = false; // reset for next time
            return;
        }

        uint256 wantBalance = balanceOfWant(); // dostupno tokena u strategiji
        // deposit available want as collateral
        if (wantBalance > _debtOutstanding && wantBalance.sub(_debtOutstanding) > minWant) {
            _depositCollateral(wantBalance.sub(_debtOutstanding));
            // we update the value
            wantBalance = balanceOfWant();
        }
    }

    function liquidatePosition(uint256 _amountNeeded) 
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // TODO: Do stuff here to free up to `_amountNeeded` from all positions back into `want`
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`

        uint256 wantBalance = balanceOfWant();
        if (wantBalance > _amountNeeded) {
            // if there is enough free want, let's use it
            return (_amountNeeded, 0);
        }

        if (_amountNeeded > wantBalance ) {
            _liqudateAmount = wantBalance;
            _loss = _amountNeeded.sub(wantBalance);
        } else {
            _liqudateAmount = _amountNeeded;
        }
    }


    function liquidateAllPositions() internal override returns (uint256 _amountFreed) {
        // likvidiraj sve otovrene pozicije. 
        // koristi se umesto prepareReturn funkcije, likvidira sve pozocije strategije i vrati sve u vault. 
        (_amountFreed, ) = liquidatePosition(type(uint256).max);
    }

    // funkciju pokrenuti u hitnim slucajevima
    // prodaje rewards tokene 
    function manualClaimAndSellRewards() external onlyVaultManagers {
        _claimAndSellRewards();
    }

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // TODO create an accurate price oracle
        return _amtInWei;
    }

    // INTERNAL ACTIONS
    function _claimAndSellRewards() internal returns (uint256) {
        uint256 stkAaveBalance = balanceOfStkAave();
        CooldownStatus cooldownStatus;
        if (stkAaveBalance > 0) {
            cooldownStatus = _checkCooldown();
        }

        // ako je status claim, claim AAVE (potrazuj aave)
        if (stkAaveBalance > 0 && cooldownStatus == CooldownStatus.Claim) {
            // povuci stkAave
            stkAave.claimRewards(address(this), type(uint256).max);
            stkAave.redeem(address(this), stkAaveBalance);
        }

        // claim stkAave from lending and borrowing, this will reset the cooldown
        incentivesController.claimRewards(getAaveAssets(), type(uint256).max, address(this));

        stkAaveBalance = balanceOfStkAave();

        // request start of cooldown period, if there's no cooldown in progress
        if (stkAaveBalance > 0 && cooldownStatus == CooldownStatus.None) {
            stkAave.cooldown();
        }
    }

    // deponuj sredstva na aave
    function _depositCollateral(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        lendingPool.deposit(address(want), amount, address(this), referral);
        return amount;
    }

    // povlaci sredstva 
    function _withdrawCollateral(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        lendingPool.withdraw(address(want), amount, address(this));
        return amount;
    }

    // placas ono sto si pozajmio
    function _repayWant(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        return lendingPool.repay(address(want), amount, 2, address(this));
    }

    // pozajmljujes sredstva od aave
    function _borrowWant(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        lendingPool.borrow(address(want), amount, 2, referral, address(this));
        return amount;
    }

    // INTERNAL VIEWS
    function balanceOfWant() internal view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfAToken() internal view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function balanceOfDebtToken() internal view returns (uint256) {
        return debtToken.balanceOf(address(this));
    }

    function balanceOfRewardToken() internal view returns (uint256) {
        return IERC20(rewardToken).balanceOf(address(this));
    }

    function balanceOfStkAave() internal view returns (uint256) {
        return IERC20(address(stkAave)).balanceOf(address(this));
    }

    function getAaveAssets() internal view returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = address(aToken);
        assets[1] = address(debtToken);
    }

    function getCurrentPosition() public view returns (uint256 deposits, uint256 borrows) {
        deposits = balanceOfAToken();
        borrows = balanceOfDebtToken();
    }
    
    function getCurrentSupply() public view returns (uint256) {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        return deposits.sub(borrows);
    }

    function _checkCooldown() internal view returns (CooldownStatus) {
        uint256 cooldownStartTimestamp = IStakedAave(stkAave).stakersCooldowns(address(this));
        uint256 COOLDOWN_SECONDS = IStakedAave(stkAave).COOLDOWN_SECONDS();
        uint256 UNSTAKE_WINDOW = IStakedAave(stkAave).UNSTAKE_WINDOW();
        uint256 nextClaimStartTimestamp = cooldownStartTimestamp.add(COOLDOWN_SECONDS);

        if (cooldownStartTimestamp == 0) {
            return CooldownStatus.None;
        }
        if (block.timestamp > nextClaimStartTimestamp && 
            block.timestamp <= nextClaimStartTimestamp.add(UNSTAKE_WINDOW)) {
            return CooldownStatus.Claim;
        }
        if (block.timestamp < nextClaimStartTimestamp) {
            return CooldownStatus.Initiated;
        }
    }

    // conversions
    function tokenToWant(address token, uint256 amount) internal view returns (uint256) {
        if (amount == 0 || address(want) == token) {
            return amount;
        }

        // KISS: just use a v2 router for quotes which aren't used in critical logic
        IUniLikeSwapRouter router = swapRouter == SwapRouter.Primary ? PRIMARY_ROUTER : SECONDARY_ROUTER;

        uint256[] memory amounts = router.getAmountsOut(amount, getTokenOutPathV2(token, address(want)));

        return amounts[amounts.length - 1];
    }
}