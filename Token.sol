// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Token is ERC20("mockUSDC", "mUSDC") {
    constructor() {
        _mint(msg.sender, 20 ether);
    }
    function mint(address account, uint256 amount) public {
        _mint(account, amount); 
    }
}