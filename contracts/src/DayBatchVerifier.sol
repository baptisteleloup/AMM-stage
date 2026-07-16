// SPDX-License-Identifier: GPL-3.0
/*
    Copyright 2021 0KIMS association.

    This file is generated with [snarkJS](https://github.com/iden3/snarkjs).

    snarkJS is a free software: you can redistribute it and/or modify it
    under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    snarkJS is distributed in the hope that it will be useful, but WITHOUT
    ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
    or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public
    License for more details.

    You should have received a copy of the GNU General Public License
    along with snarkJS. If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity >=0.7.0 <0.9.0;

contract Groth16Verifier {
    // Scalar field size
    uint256 constant r    = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    // Base field size
    uint256 constant q   = 21888242871839275222246405745257275088696311157297823662689037894645226208583;

    // Verification Key data
    uint256 constant alphax  = 20474411337070080093100328173488826151254879240007968652595380193814692879939;
    uint256 constant alphay  = 8596660381321376575971174922902345015484615343683155463809957687263854635490;
    uint256 constant betax1  = 18014983045312448875011450281404768098128310186880471749178421251452851164611;
    uint256 constant betax2  = 8190030805500788118585809052951062582072133211404175432472868446764463368964;
    uint256 constant betay1  = 15131183645655093423572312783753296708146689204019233359892893219112994151677;
    uint256 constant betay2  = 2870336168863293956847420897536244112432285722949212894893104597592625163102;
    uint256 constant gammax1 = 11559732032986387107991004021392285783925812861821192530917403151452391805634;
    uint256 constant gammax2 = 10857046999023057135944570762232829481370756359578518086990519993285655852781;
    uint256 constant gammay1 = 4082367875863433681332203403145435568316851327593401208105741076214120093531;
    uint256 constant gammay2 = 8495653923123431417604973247489272438418190587263600148770280649306958101930;
    uint256 constant deltax1 = 10229906988351934477264115646374817974785093840270572675015005567982520594521;
    uint256 constant deltax2 = 7798869441038880637622400528943261761141413871877823840689591553837013123257;
    uint256 constant deltay1 = 12583541474215694943969892026033522812823543468551332855581923567161111939245;
    uint256 constant deltay2 = 2910433283278612696080541679420868896186843567946154897282023009696968188479;

    
    uint256 constant IC0x = 298683510323324636283945017676464667848915695170627583686625015042760359427;
    uint256 constant IC0y = 16799375378067669379412163829764849536705827347110063574867602366307632950680;
    
    uint256 constant IC1x = 18264604787817069292055510709062132659882463302915014479333646355928340282667;
    uint256 constant IC1y = 2945878136008127159198930612709524019923482242009961590223248903097928990658;
    
    uint256 constant IC2x = 5779237568401172349909900258399768811998279108130030996647249639373788841463;
    uint256 constant IC2y = 3136292155909448974031764565026641579554440974232202072464677153504155789777;
    
    uint256 constant IC3x = 529090500317898508558135034467094520488666768488074624909364123718446906401;
    uint256 constant IC3y = 2680786175132226915619519430896317297744694970451692107131073907285236477041;
    
    uint256 constant IC4x = 14180036010712316876220166421145309143373065230616480805223284234454988487069;
    uint256 constant IC4y = 17948803719311987056554733760850280437798403855000785739417193023952481658009;
    
    uint256 constant IC5x = 1220494586041183566931603823971071951746336813568071294391627770804432867792;
    uint256 constant IC5y = 2238966492778847173060847819908616178548986784904066003368679689143549643518;
    
    uint256 constant IC6x = 16332179010132551368622781319759132290781882094738789540172186158834299006962;
    uint256 constant IC6y = 10446630469933382873485645776306156361174222569256145205387945954397589926147;
    
    uint256 constant IC7x = 5012435073849977238537935650384212204425833537085342846298256140784851460360;
    uint256 constant IC7y = 3296656677760824747483418226730857603991826797891797057785919803874199753107;
    
    uint256 constant IC8x = 18253615058105883075974483620776917682680821423116815523915496225136230161495;
    uint256 constant IC8y = 5412989523559965215778547717428091295003622858440764302540038687809366149457;
    
    uint256 constant IC9x = 18183804219249033066597170371294295070677752680464409641011958978463966080359;
    uint256 constant IC9y = 10725547378179971455081161571054423516879129623990200657368276261283213996759;
    
 
    // Memory data
    uint16 constant pVk = 0;
    uint16 constant pPairing = 128;

    uint16 constant pLastMem = 896;

    function verifyProof(uint[2] calldata _pA, uint[2][2] calldata _pB, uint[2] calldata _pC, uint[9] calldata _pubSignals) public view returns (bool) {
        assembly {
            function checkField(v) {
                if iszero(lt(v, r)) {
                    mstore(0, 0)
                    return(0, 0x20)
                }
            }
            
            // G1 function to multiply a G1 value(x,y) to value in an address
            function g1_mulAccC(pR, x, y, s) {
                let success
                let mIn := mload(0x40)
                mstore(mIn, x)
                mstore(add(mIn, 32), y)
                mstore(add(mIn, 64), s)

                success := staticcall(sub(gas(), 2000), 7, mIn, 96, mIn, 64)

                if iszero(success) {
                    mstore(0, 0)
                    return(0, 0x20)
                }

                mstore(add(mIn, 64), mload(pR))
                mstore(add(mIn, 96), mload(add(pR, 32)))

                success := staticcall(sub(gas(), 2000), 6, mIn, 128, pR, 64)

                if iszero(success) {
                    mstore(0, 0)
                    return(0, 0x20)
                }
            }

            function checkPairing(pA, pB, pC, pubSignals, pMem) -> isOk {
                let _pPairing := add(pMem, pPairing)
                let _pVk := add(pMem, pVk)

                mstore(_pVk, IC0x)
                mstore(add(_pVk, 32), IC0y)

                // Compute the linear combination vk_x
                
                g1_mulAccC(_pVk, IC1x, IC1y, calldataload(add(pubSignals, 0)))
                
                g1_mulAccC(_pVk, IC2x, IC2y, calldataload(add(pubSignals, 32)))
                
                g1_mulAccC(_pVk, IC3x, IC3y, calldataload(add(pubSignals, 64)))
                
                g1_mulAccC(_pVk, IC4x, IC4y, calldataload(add(pubSignals, 96)))
                
                g1_mulAccC(_pVk, IC5x, IC5y, calldataload(add(pubSignals, 128)))
                
                g1_mulAccC(_pVk, IC6x, IC6y, calldataload(add(pubSignals, 160)))
                
                g1_mulAccC(_pVk, IC7x, IC7y, calldataload(add(pubSignals, 192)))
                
                g1_mulAccC(_pVk, IC8x, IC8y, calldataload(add(pubSignals, 224)))
                
                g1_mulAccC(_pVk, IC9x, IC9y, calldataload(add(pubSignals, 256)))
                

                // -A
                mstore(_pPairing, calldataload(pA))
                mstore(add(_pPairing, 32), mod(sub(q, calldataload(add(pA, 32))), q))

                // B
                mstore(add(_pPairing, 64), calldataload(pB))
                mstore(add(_pPairing, 96), calldataload(add(pB, 32)))
                mstore(add(_pPairing, 128), calldataload(add(pB, 64)))
                mstore(add(_pPairing, 160), calldataload(add(pB, 96)))

                // alpha1
                mstore(add(_pPairing, 192), alphax)
                mstore(add(_pPairing, 224), alphay)

                // beta2
                mstore(add(_pPairing, 256), betax1)
                mstore(add(_pPairing, 288), betax2)
                mstore(add(_pPairing, 320), betay1)
                mstore(add(_pPairing, 352), betay2)

                // vk_x
                mstore(add(_pPairing, 384), mload(add(pMem, pVk)))
                mstore(add(_pPairing, 416), mload(add(pMem, add(pVk, 32))))


                // gamma2
                mstore(add(_pPairing, 448), gammax1)
                mstore(add(_pPairing, 480), gammax2)
                mstore(add(_pPairing, 512), gammay1)
                mstore(add(_pPairing, 544), gammay2)

                // C
                mstore(add(_pPairing, 576), calldataload(pC))
                mstore(add(_pPairing, 608), calldataload(add(pC, 32)))

                // delta2
                mstore(add(_pPairing, 640), deltax1)
                mstore(add(_pPairing, 672), deltax2)
                mstore(add(_pPairing, 704), deltay1)
                mstore(add(_pPairing, 736), deltay2)


                let success := staticcall(sub(gas(), 2000), 8, _pPairing, 768, _pPairing, 0x20)

                isOk := and(success, mload(_pPairing))
            }

            let pMem := mload(0x40)
            mstore(0x40, add(pMem, pLastMem))

            // Validate that all evaluations ∈ F
            
            checkField(calldataload(add(_pubSignals, 0)))
            
            checkField(calldataload(add(_pubSignals, 32)))
            
            checkField(calldataload(add(_pubSignals, 64)))
            
            checkField(calldataload(add(_pubSignals, 96)))
            
            checkField(calldataload(add(_pubSignals, 128)))
            
            checkField(calldataload(add(_pubSignals, 160)))
            
            checkField(calldataload(add(_pubSignals, 192)))
            
            checkField(calldataload(add(_pubSignals, 224)))
            
            checkField(calldataload(add(_pubSignals, 256)))
            

            // Validate all evaluations
            let isValid := checkPairing(_pA, _pB, _pC, _pubSignals, pMem)

            mstore(0, isValid)
             return(0, 0x20)
         }
     }
 }
