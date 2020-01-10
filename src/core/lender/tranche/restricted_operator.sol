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

pragma solidity >=0.4.24;

import "./operator.sol";

// RestrictedOperator restricts the allowance of users
// the allowanceActive flag actives the restriction
// openAccess by default deactivated
contract RestrictedOperator is Operator {
    mapping (address => uint) maxCurrency;  // uint(-1) unlimited access by convention
    mapping (address => uint) maxToken;     // uint(-1) unlimited access by convention

    constructor(address tranche_, address assessor_)
    Operator(tranche_, assessor_) public {}

    function approve(address usr, uint maxToken_, uint maxCurrency_) public auth {
        if(investors[usr] == 0) {
            investors[usr] = 1;
        }
        maxCurrency[msg.sender] = maxCurrency_;
        maxToken[msg.sender] = maxToken_;
    }

    function supply(uint currencyAmount) public auth_investor {
        if (maxCurrency[msg.sender] != uint(-1)) {
            require(maxCurrency[msg.sender] >= currencyAmount);
            maxCurrency[msg.sender] = maxCurrency[msg.sender] - currencyAmount;
        }
        super.supply(currencyAmount);
    }

    function redeem(uint tokenAmount) public auth_investor {
        if (maxToken[msg.sender] != uint(-1)) {
            require(maxToken[msg.sender] >= tokenAmount);
            maxToken[msg.sender] = maxToken[msg.sender] - tokenAmount;
        }
        super.redeem(tokenAmount);
    }
}
