// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

 /**
  * @title Burnable interface
  */
interface IBurnable {
	function burn(uint256 amount) external;
}