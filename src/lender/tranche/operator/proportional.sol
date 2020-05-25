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

import "ds-note/note.sol";
import "tinlake-math/math.sol";
import "tinlake-auth/auth.sol";

contract TrancheLike {
    function supply(address usr, uint currencyAmount, uint tokenAmount) public;
    function redeem(address usr, uint currencyAmount, uint tokenAmount) public;
    function tokenSupply() public returns (uint);
}

contract AssessorLike {
    function calcAndUpdateTokenPrice(address tranche) public returns(uint);
    function supplyApprove(address tranche, uint currencyAmount) public returns(bool);
    function redeemApprove(address tranche, uint currencyAmount) public returns(bool);
    function tokenAmountForONE() public returns(uint);
}

contract DistributorLike {
    function balance() public;
}

contract ProportionalOperator is Math, DSNote, Auth  {
    TrancheLike public tranche;
    AssessorLike public assessor;
    DistributorLike public distributor;

    // investor mappings
    // each value in a own map for gas-optimization
    mapping (address => uint) public supplyMaximum;
    mapping (address => uint) public tokenReceived;
    // helper we could also calculate based on principalRedeemed
    mapping (address => uint) public tokenRedeemed;

    // currency amount of investor's share in the pool which has already been redeemed
    // denominated: in totalCurrencyReturned units
    mapping (address => uint) public currencyRedeemed;

    // principal amount of investor's share in the pool which has already been redeemed
    // denominated: in totalPrincipalReturned units
    mapping (address => uint) public principalRedeemed;

    bool public supplyAllowed  = true;

    // denominated in currency
    uint public totalCurrencyReturned;

    // denominated in currency
    uint public totalPrincipalReturned;

    // denominated in currency
    uint public totalPrincipal;

    bool public migrated = false;

    constructor(address tranche_, address assessor_, address distributor_) public {
        wards[msg.sender] = 1;
        tranche = TrancheLike(tranche_);
        assessor = AssessorLike(assessor_);
        distributor = DistributorLike(distributor_);

    }

    function migrate() public {
        require(migrated == false);
        address oldVersion = address(0xD9ced1c2A058f4d60e392f6DA2898594138B5ac0);

        ProportionalOperator old = ProportionalOperator(oldVersion);

        /*

        address payable[10] memory investors = [
            address(0xFce0d496D9059e9Ba589836EDF39AB204dBEe04f),
            address(0x5D28d3A7313d391e9B24C899fC6AB84c9a3d814B),
            address(0xb9d64860F0064DBFB9b64065238dDA80D36FcA17),
            address(0xb285c461109C2112dB37087C4a907c2ee7c20e86),
            address(0x00fC7fCf89ca511D0FC22fF5Fb5Dc8D5BE3733AD),
            address(0x022a21f88E09fB72Be21fA0D9E083a465A38B586),
            address(0xC2F61a6eEEC48d686901D325CDE9233b81c793F3),
            address(0xa3D4926721E60fA5844Cea20FF3dEA1E72B10462),
            address(0x83662DAa45F8B74a589cCF0C0587022678ca2306),
            address(0xFBAF25cD02C3C3721a660F1fdaC4d7AAC60aA54F)];
        */

        address payable[2] memory investors = [
        address(0xEcEDFd8BA8ae39a6Bd346Fe9E5e0aBeA687fFF31),
        address(0x956378240adc1e2Ce39bCA0e957bE5324e846a4E)];


        totalPrincipal = old.totalPrincipal();

        for (uint i = 0; i < 2; i++) {
            supplyMaximum[investors[i]] = old.supplyMaximum(investors[i]);
            tokenReceived[investors[i]] = old.tokenReceived(investors[i]);
        }

        migrated = true;
    }

    /// sets the dependency to another contract
    function depend(bytes32 contractName, address addr) public auth {
        if (contractName == "tranche") { tranche = TrancheLike(addr); }
        else if (contractName == "assessor") { assessor = AssessorLike(addr); }
        else if (contractName == "distributor") { distributor = DistributorLike(addr); }
        else revert();
    }

    function file(bytes32 what, address usr, uint supplyMaximum_, uint tokenReceived_, uint tokenRedeemed_, uint currencyRedeemed_, uint principalRedeemed_) external auth {
        if(what == "resetUsr") {
            approve(usr, supplyMaximum_);
            tokenReceived[usr] = tokenReceived_;
            tokenRedeemed[usr] = tokenRedeemed_;
            currencyRedeemed[usr] = currencyRedeemed_;
            principalRedeemed[usr] = principalRedeemed_;
        } else { revert("unknown parameter");}
    }

    function file(bytes32 what, bool supplyAllowed_) public auth {
        if(what == "supplyAllowed") {
            supplyAllowed = supplyAllowed_;
        }
    }
    /// defines the max amount of currency for supply
    function approve(address usr, uint currencyAmount) public auth {
        supplyMaximum[usr] = currencyAmount;
    }

    function updateReturned(uint currencyReturned_, uint principalReturned_) public auth {
        totalCurrencyReturned  = safeAdd(totalCurrencyReturned, currencyReturned_);
        totalPrincipalReturned = safeAdd(totalPrincipalReturned, principalReturned_);
    }

    function setReturned(uint currencyReturned_, uint principalReturned_) public auth {
        totalCurrencyReturned  = currencyReturned_;
        totalPrincipalReturned = principalReturned_;
    }

    /// only approved investors can supply and approved
    function supply(uint currencyAmount) external note {
        require(supplyAllowed);

        tokenReceived[msg.sender] = safeAdd(tokenReceived[msg.sender], currencyAmount);

        require(tokenReceived[msg.sender] <= supplyMaximum[msg.sender], "currency-amount-above-supply-maximum");

        require(assessor.supplyApprove(address(tranche), currencyAmount), "supply-not-approved");

        // pre-defined tokenPrice of ONE
        uint tokenAmount = currencyAmount;

        tranche.supply(msg.sender, currencyAmount, tokenAmount);

        totalPrincipal = safeAdd(totalPrincipal, currencyAmount);

        distributor.balance();
    }

    /// redeem is proportional allowed
    function redeem(uint tokenAmount) external note {
        distributor.balance();

        // maxTokenAmount that can still be redeemed based on the investor's share in the pool
        uint maxTokenAmount = calcMaxRedeemToken(msg.sender);

        if (tokenAmount > maxTokenAmount) {
            tokenAmount = maxTokenAmount;
        }

        uint currencyAmount = calcRedeemCurrencyAmount(msg.sender, tokenAmount, maxTokenAmount);

        require(assessor.redeemApprove(address(tranche), currencyAmount), "redeem-not-approved");
        tokenRedeemed[msg.sender] = safeAdd(tokenRedeemed[msg.sender], tokenAmount);
        tranche.redeem(msg.sender, currencyAmount, tokenAmount);
    }

    /// calculates the current max amount of tokens a user can redeem
    /// the max amount of token depends on the total principal returned
    /// and previous redeem actions of the user
    function calcMaxRedeemToken(address usr) public view returns(uint) {
        if (supplyAllowed) {
            return 0;
        }
        // assumes a initial token price of ONE
        return safeSub(rmul(rdiv(totalPrincipalReturned, totalPrincipal), tokenReceived[usr]), tokenRedeemed[usr]);
    }

    /// calculates the amount of currency a user can redeem for a specific token amount
    /// the used token price for the conversion can be different among users depending on their
    /// redeem history.
    function calcRedeemCurrencyAmount(address usr, uint tokenAmount, uint maxTokenAmount) internal returns(uint) {
        // solidity gas-optimized calculation avoiding local variable if possible
        uint currencyAmount = rmul(tokenAmount, calcTokenPrice(usr));

        uint redeemRatio = rdiv(tokenAmount, maxTokenAmount);

        currencyRedeemed[usr] = safeAdd(rmul(safeSub(totalCurrencyReturned, currencyRedeemed[usr]),
            redeemRatio), currencyRedeemed[usr]);

        principalRedeemed[usr] = safeAdd(rmul(safeSub(totalPrincipalReturned, principalRedeemed[usr]),
            redeemRatio), principalRedeemed[usr]);

        return currencyAmount;
    }

    /// returns the tokenPrice denominated in RAD (10^27)
    function calcTokenPrice(address usr) public view returns (uint) {
        if (totalPrincipalReturned == 0)  {
            return ONE;
        }
       return rdiv(safeSub(totalCurrencyReturned, currencyRedeemed[usr]),
           safeSub(totalPrincipalReturned, principalRedeemed[usr]));
    }
}
