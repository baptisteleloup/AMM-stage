// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { UD60x18, ud } from "@prb/math/src/UD60x18.sol";
import { Pricing } from "./Pricing.sol";

/// @title  Market — collecte des ordres des prosumers
/// @notice Stocke les netputs individuels d'une session, avant agrégation.
contract Market {

    /// @dev Ordre soumis par un prosumer. netput signé, échelle 1e18 :
    ///      > 0 = offre (kWh), < 0 = demande (kWh).
    struct Order {
        int256 netput;
        bool exists; // gère l'unicité dans le tableau `prosumers`
    }

    mapping(address => Order) public orderOf;
    address[] public prosumers;

    UD60x18 public lambdaLow;   // feed-in
    UD60x18 public lambdaHigh;  // retail        

    event OrderSubmitted(address indexed prosumer, int256 netput);

    constructor(UD60x18 _lambdaLow, UD60x18 _lambdaHigh) {
        require(_lambdaLow.unwrap() <= _lambdaHigh.unwrap(), "lambdaLow > lambdaHigh");
        lambdaLow = _lambdaLow;
        lambdaHigh = _lambdaHigh;
    }


    /// @notice Soumettre ou mettre à jour son netput pour la session.
    function submitOrder(int256 netput) external {
        if (!orderOf[msg.sender].exists) {
            prosumers.push(msg.sender); // premier ordre → on l'ajoute à la liste
        }
        orderOf[msg.sender] = Order({ netput: netput, exists: true });
        emit OrderSubmitted(msg.sender, netput);
    }

    /// @notice Décompose un netput en (offre, demande) non-négatifs.
    function decompose(int256 netput) public pure returns (uint256 supply, uint256 demand) {
        if (netput > 0)      supply = uint256(netput);
        else if (netput < 0) demand = uint256(-netput);
        // netput == 0 : ni offre ni demande, les deux restent à 0
    }

    /// @notice Nombre de prosumers ayant soumis (pratique pour les tests).
    function prosumerCount() external view returns (uint256) {
        return prosumers.length;
    }

     /// @notice Agrège tous les ordres en (s, d).
    function aggregate() public view returns (UD60x18 s, UD60x18 d) {
        uint256 totalS;
        uint256 totalD;
        for (uint256 i = 0; i < prosumers.length; i++) {
            int256 netput = orderOf[prosumers[i]].netput;
            (uint256 sn, uint256 dn) = decompose(netput);
            totalS += sn;
            totalD += dn;
        }
        s = ud(totalS);
        d = ud(totalD);
    }

    /// @notice Agrège puis calcule les prix de clearing (r, c) via le pricer.
    function clearingPrices() external view returns (UD60x18 r, UD60x18 c) {
        (UD60x18 s, UD60x18 d) = aggregate();
        (r, c) = Pricing.prices(s, d, lambdaLow, lambdaHigh);
    }

    /// @notice Agrège puis calcule les totaux du settlement (Ctotal, Rtotal),
    ///         jambes grid incluses.
    function settlementTotals() external view returns (UD60x18 cTotal, UD60x18 rTotal) {
        (UD60x18 s, UD60x18 d) = aggregate();
        (cTotal, rTotal) = Pricing.totals(s, d, lambdaLow, lambdaHigh);
    }

}