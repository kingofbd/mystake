// SPDX-License-Identifier: MIT
// 声明合约使用的Solidity版本（0.8.20包含溢出检查等安全特性）
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MetaNode is ERC20 {
    constructor(uint256 _totalSupply) ERC20("MetaNode", "MNODE") {
        _mint(msg.sender, _totalSupply);
    }
}
