// Copyright (C) 2019 Centrifuge

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

pragma solidity >=0.5.12;

import "ds-note/note.sol";
import "tinlake-math/math.sol";
import "tinlake-auth/auth.sol";

contract TrancheLike {
    function balance() public returns(uint);
    function tokenSupply() public returns(uint);
}

contract SeniorTrancheLike {
    function debt() public returns(uint);
    function borrowed() public returns(uint);
    function interest() public returns(uint);

    function ratePerSecond() public returns(uint);
    function lastUpdated() public returns(uint);
}

contract PileLike {
    function debt() public returns(uint);
}

contract PoolLike {
    function totalValue() public returns(uint);
}

contract BaseAssessor is Math, Auth {
    // --- Tranches ---
    address public senior;
    address public junior;

    PoolLike public pool;

    // amounts of token for a token price of ONE
    // constant factor multiplied with the token price
    uint public tokenAmountForONE;

    // denominated in RAD
    // ONE == 100%
    // only needed for two tranches. if only one tranche is used == 0
    uint public minJuniorRatio;

    // --- Assessor ---
    // computes the current asset value for tranches.
    constructor() public {
        wards[msg.sender] = 1;
        tokenAmountForONE = 1;
    }

    // --- Calls ---
    function depend(bytes32 what, address addr_) public auth {
        if (what == "junior") { junior = addr_; }
        else if (what == "senior") { senior = addr_; }
        else if (what == "pool") { pool = PoolLike(addr_); }
        else revert();
    }

    function file(bytes32 what, uint value) public auth {
        if (what == "tokenAmountForONE") { tokenAmountForONE = value; }
        else if (what == "minJuniorRatio") { minJuniorRatio = value; }
        else revert();
    }

    function calcAssetValue(address tranche) public returns(uint) {
        uint trancheReserve = TrancheLike(tranche).balance();
        uint poolValue = pool.totalValue();
        if (tranche == junior) {
            return _calcJuniorAssetValue(poolValue, trancheReserve, _seniorDebt());
        }
        return _calcSeniorAssetValue(poolValue, trancheReserve, SeniorTrancheLike(tranche).debt(), _juniorReserve());
    }

    function calcTokenPrice(address tranche) public returns (uint) {
        return safeMul(_calcTokenPrice(tranche), tokenAmountForONE);
    }

    function _calcTokenPrice(address tranche) internal returns (uint) {
        uint tokenSupply = TrancheLike(tranche).tokenSupply();
        uint assetValue = calcAssetValue(tranche);
        if (tokenSupply == 0) {
            return ONE;
        }
        if (assetValue == 0) {
            revert("tranche is bankrupt");
        }
        return rdiv(assetValue, tokenSupply);
    }

    // Tranche.assets (Junior) = (Pool.value + Tranche.reserve - Senior.debt) > 0 && (Pool.value - Tranche.reserve - Senior.debt) || 0
    function _calcJuniorAssetValue(uint poolValue, uint trancheReserve, uint seniorDebt) internal pure returns (uint) {
        int assetValue = int(poolValue + trancheReserve - seniorDebt);
        return (assetValue > 0) ? uint(assetValue) : 0;
    }

    // Tranche.assets (Senior) = (Tranche.debt < (Pool.value + Junior.reserve)) && (Senior.debt + Tranche.reserve) || (Pool.value + Junior.reserve + Tranche.reserve)
    function _calcSeniorAssetValue(uint poolValue, uint trancheReserve, uint trancheDebt, uint juniorReserve) internal pure returns (uint) {
        return ((poolValue + juniorReserve) >= trancheDebt) ? (trancheDebt + trancheReserve) : (poolValue + juniorReserve + trancheReserve);
    }

    function _juniorReserve() internal returns (uint) {
        return TrancheLike(junior).balance();
    }

    function _seniorDebt() internal returns (uint) {
        return (senior != address(0x0)) ? SeniorTrancheLike(senior).debt() : 0;
    }


    function calcMaxSeniorAssetValue() public returns (uint) {
        uint juniorAssetValue = calcAssetValue(junior);
        if (juniorAssetValue == 0) {
            return 0;
        }
        return safeSub(rdiv(juniorAssetValue, minJuniorRatio), juniorAssetValue);
    }

    function calcMinJuniorAssetValue() public returns (uint) {
        if (senior == address(0)) {
            return 0;
        }
        uint seniorAssetValue = calcAssetValue(senior);
        if (seniorAssetValue == 0) {
            return uint(-1);
        }
        return rmul(rdiv(seniorAssetValue, ONE-minJuniorRatio), minJuniorRatio);
    }

    // only needed for external contracts
    function currentJuniorRatio() public returns(uint) {
        if (senior == address(0)) {
            return ONE;
        }
        uint juniorAssetValue = calcAssetValue(junior);
        return rdiv(juniorAssetValue, safeAdd(juniorAssetValue, calcAssetValue(senior)));
    }

    function supplyApprove(address tranche, uint currencyAmount) public returns(bool) {
        // always allowed to supply into junior || minJuniorRatio feature not activated
        if (tranche == junior || minJuniorRatio == 0) {
            return true;
        }

        if (tranche == senior && safeAdd(calcAssetValue(senior), currencyAmount) <= calcMaxSeniorAssetValue()) {
            return true;
        }
        return false;
    }

    function redeemApprove(address tranche, uint currencyAmount) public returns(bool) {
        // always allowed to redeem into senior || minJuniorRatio feature not activated || only single tranche
        if (tranche == senior || minJuniorRatio == 0 || senior == address(0)) {
            return true;
        }

        if (tranche == junior && safeSub(calcAssetValue(junior), currencyAmount) >= calcMinJuniorAssetValue()) {
            return true;

        }
        return false;
    }
}