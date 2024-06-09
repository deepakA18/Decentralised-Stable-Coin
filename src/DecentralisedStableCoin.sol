// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DecentralisedStableCoin is ERC20Burnable, Ownable {

    error DecentralisedStableCoin__AmountCannotBeZero();
    error DecentralisedStableCoin__BalanceShouldBeMoreThanAmount();
    error DecentralisedStableCoin__NotZeroAddress();

    constructor() ERC20("StableCoin","SC") Ownable(address(msg.sender)){}
    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralisedStableCoin__AmountCannotBeZero();
        }
        if (balance < _amount) {
            revert DecentralisedStableCoin__BalanceShouldBeMoreThanAmount();
        }
        super.burn(_amount); //ERC20Burnable
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralisedStableCoin__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralisedStableCoin__AmountCannotBeZero();
        }
        _mint(_to, _amount); //ERC20
        return true;
    }
}
