// Copyright (C) 2020 Centrifuge
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.5.15 <0.6.0;
pragma experimental ABIEncoderV2;

import "tinlake-auth/auth.sol";
import "tinlake-math/math.sol";
import "./fixed_point.sol";


contract ERC20Like {
    function balanceOf(address) public view returns (uint);

    function transferFrom(address, address, uint) public returns (bool);

    function mint(address, uint) public;

    function burn(address, uint) public;

    function totalSupply() public view returns (uint);
}

contract TickerLike {
    function currentEpoch() public returns (uint);
}

contract Tranche is Math, Auth, FixedPoint {
    mapping(uint => Epoch) public epochs;

    struct Epoch {
        // denominated in 10^27
        // percentage ONE == 100%
        Fixed27 redeemFulfillment;
        // denominated in 10^27
        // percentage ONE == 100%
        Fixed27 supplyFulfillment;
        // tokenPrice after end of epoch
        Fixed27 tokenPrice;
        bool executed;
    }

    struct UserOrder {
        uint orderedInEpoch;
        uint supplyCurrencyAmount;
        uint redeemTokenAmount;
    }

    mapping(address => UserOrder) public users;

    uint public  globalSupply;
    uint public  globalRedeem;

    ERC20Like public currency;
    ERC20Like public token;
    TickerLike public ticker;
    address public reserve;

    address self;

    uint public currentEpoch;

    bool public waitingForUpdate  = false;

    constructor(address currency_, address token_) public {
        wards[msg.sender] = 1;
        currentEpoch = 1;
        token = ERC20Like(token_);
        currency = ERC20Like(currency_);


        self = address(this);
    }

    function balance() external view returns (uint) {
        return currency.balanceOf(self);
    }

    function tokenSupply() external view returns (uint) {
        return token.totalSupply();
    }

    function depend(bytes32 contractName, address addr) public auth {
        if (contractName == "token") {token = ERC20Like(addr);}
        else if (contractName == "currency") {currency = ERC20Like(addr);}
        else if (contractName == "ticker") {ticker = TickerLike(addr);}
        else if (contractName == "reserve") {reserve = addr;}
        else revert();
    }

    // supplyOrder function can be used to place or revoke an supply
    function supplyOrder(address usr, uint newSupplyAmount) public auth {
        require(users[usr].orderedInEpoch == 0 || users[usr].orderedInEpoch == currentEpoch, "disburse required");
        users[usr].orderedInEpoch = currentEpoch;

        uint currentSupplyAmount = users[usr].supplyCurrencyAmount;

        users[usr].supplyCurrencyAmount = newSupplyAmount;

        globalSupply = safeAdd(safeSub(globalSupply, currentSupplyAmount), newSupplyAmount);

        if (newSupplyAmount > currentSupplyAmount) {
            uint delta = safeSub(newSupplyAmount, currentSupplyAmount);
            require(currency.transferFrom(usr, self, delta), "currency-transfer-failed");
            return;
        }
        uint delta = safeSub(currentSupplyAmount, newSupplyAmount);
        if (delta > 0) {
            require(currency.transferFrom(self, usr, delta), "currency-transfer-failed");
        }
    }

    // redeemOrder function can be used to place or revoke a redeem
    function redeemOrder(address usr, uint newRedeemAmount) public auth {
        require(users[usr].orderedInEpoch == 0 || users[usr].orderedInEpoch == currentEpoch, "disburse required");
        users[usr].orderedInEpoch = currentEpoch;

        uint currentRedeemAmount = users[usr].redeemTokenAmount;
        users[usr].redeemTokenAmount = newRedeemAmount;
        globalRedeem = safeAdd(safeSub(globalRedeem, currentRedeemAmount), newRedeemAmount);

        if (newRedeemAmount > currentRedeemAmount) {
            uint delta = safeSub(newRedeemAmount, currentRedeemAmount);
            require(token.transferFrom(usr, self, delta), "token-transfer-failed");
            return;
        }

        uint delta = safeSub(currentRedeemAmount, newRedeemAmount);
        if (delta > 0) {
            require(token.transferFrom(self, usr, delta), "token-transfer-failed");
        }
    }

    function calcDisburse(address usr) public view returns(uint payoutCurrencyAmount, uint payoutTokenAmount, uint usrRemainingSupply, uint usrRemainingRedeem) {
        // no disburse possible in this epoch
        if (users[usr].orderedInEpoch  == currentEpoch) {
            return (0, 0, users[usr].supplyCurrencyAmount, users[usr].redeemTokenAmount);
        }

        uint epochIdx = users[usr].orderedInEpoch;

        uint usrRemainingSupply = users[usr].supplyCurrencyAmount;
        uint usrRemainingRedeem = users[usr].redeemTokenAmount;

        while(epochIdx != currentEpoch && (usrRemainingSupply != 0 || usrRemainingRedeem != 0 )){
            if(usrRemainingSupply != 0) {
                usrRemainingSupply = safeSub(usrRemainingSupply, rmul(usrRemainingSupply, epochs[epochIdx].tokenPrice.value));
            }

            if(usrRemainingRedeem != 0) {
                usrRemainingRedeem = safeSub(usrRemainingRedeem, rmul(usrRemainingRedeem, epochs[epochIdx].tokenPrice.value));

            }
            epochIdx = safeAdd(epochIdx, 1);
        }

        // calc payout amount
        uint payoutCurrencyAmount = safeSub(users[usr].supplyCurrencyAmount, usrRemainingSupply);
        uint payoutTokenAmount = safeSub(users[usr].redeemTokenAmount, usrRemainingRedeem);

        return (payoutCurrencyAmount, payoutTokenAmount, usrRemainingSupply, usrRemainingRedeem);

    }

    // the disburse function can be used after an epoch is over to receive currency and tokens
    function disburse(address usr) public auth returns (uint payoutCurrencyAmount, uint payoutTokenAmount, uint usrRemainingSupply, uint usrRemainingRedeem) {
        require(users[usr].orderedInEpoch < currentEpoch);

        (payoutCurrencyAmount, payoutTokenAmount,
         usrRemainingSupply,  usrRemainingRedeem)  = calcDisburse(usr);

        users[usr].supplyCurrencyAmount = usrRemainingSupply;
        users[usr].redeemTokenAmount = usrRemainingRedeem;

        // remaining orders are placed in the current epoch
        // which allows to change the order and therefore receive it back
        users[usr].orderedInEpoch = currentEpoch;

        if (payoutCurrencyAmount > 0) {
            require(currency.transferFrom(self, usr, payoutCurrencyAmount), "currency-transfer-failed");
        }

        if (payoutTokenAmount > 0) {
            require(token.transferFrom(self, usr, payoutCurrencyAmount), "token-transfer-failed");
        }
        return (payoutCurrencyAmount, payoutTokenAmount, usrRemainingSupply, usrRemainingRedeem);

    }

    // called by epoch coordinator in epoch execute method
    function epochUpdate(uint supplyFulfillment_, uint redeemFulfillment_, uint tokenPrice_, uint epochSupplyCurrency, uint epochRedeemCurrency) public auth {
        require(waitingForUpdate == true);
        waitingForUpdate = false;

        uint epochID = safeSub(currentEpoch, 1);

        epochs[epochID].supplyFulfillment.value = supplyFulfillment_;
        epochs[epochID].redeemFulfillment.value = redeemFulfillment_;
        epochs[epochID].tokenPrice.value = tokenPrice_;
        epochs[epochID].executed = true;

        // currency needs to be converted to tokenAmount with current token price
        adjustTokenBalance(epochID, rdiv(epochSupplyCurrency, tokenPrice_), rdiv(epochRedeemCurrency, tokenPrice_));
        adjustCurrencyBalance(epochID, epochSupplyCurrency, epochRedeemCurrency);

        globalSupply = safeAdd(safeSub(globalSupply, epochSupplyCurrency), rmul(epochSupplyCurrency, safeSub(ONE, epochs[epochID].supplyFulfillment.value)));
        globalRedeem = safeAdd(safeSub(globalRedeem, epochRedeemCurrency), rmul(epochRedeemCurrency, safeSub(ONE, epochs[epochID].redeemFulfillment.value)));

    }

    function closeEpoch() public auth returns (uint globalSupply_, uint globalRedeem_) {
        currentEpoch = safeAdd(currentEpoch, 1);
        waitingForUpdate = true;
        return (globalSupply, globalRedeem);
    }


    // adjust token balance after epoch execution -> min/burn tokens
    function adjustTokenBalance(uint epochID, uint epochSupply, uint epochRedeem) internal {
        // mint amount of tokens for that epoch
        uint mintAmount = rdiv(rmul(epochSupply, epochs[epochID].supplyFulfillment.value), epochs[epochID].tokenPrice.value);

        // burn amount of tokens for that epoch
        uint burnAmount = rmul(epochRedeem, epochs[epochID].redeemFulfillment.value);
       // burn tokens that are not needed for disbursement
        if (burnAmount > mintAmount) {
            uint diff = safeSub(burnAmount, mintAmount);
            token.burn(self, diff);
            return;
        }
        // mint tokens that are required for disbursement
        uint diff = safeSub(mintAmount, burnAmount);
        if (diff > 0) {
            token.mint(self, diff);
        }
    }

    // adjust currency balance after epoch execution -> receive/send currency from/to reserve
    function adjustCurrencyBalance(uint epochID, uint epochSupply, uint epochRedeem) internal {
        // currency that was supplied in this epoch
        uint currencySupplied = rmul(epochSupply, epochs[epochID].supplyFulfillment.value);
        // currency required for redemption
        uint currencyRequired = rmul(rmul(epochRedeem, epochs[epochID].redeemFulfillment.value), epochs[epochID].tokenPrice.value);

        if (currencySupplied > currencyRequired) {
            // send surplus currency to reserve
            uint diff = safeSub(currencySupplied, currencyRequired);
            require(currency.transferFrom(self, reserve, diff), "currency-transfer-failed");
            return;
        }
        uint diff = safeSub(currencyRequired, currencySupplied);
        if (diff > 0) {
            // get missing currency from reserve
            require(currency.transferFrom(reserve, self, diff), "currency-transfer-failed");
        }
    }

}
