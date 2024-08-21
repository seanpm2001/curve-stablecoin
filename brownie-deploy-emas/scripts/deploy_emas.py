from brownie import network, accounts
from brownie import ChainlinkEMA


OBSERVATIONS = 20
INTERVAL = 30

FEEDS = {
    'optimism-main': [
        ('ETH', '0x13e3Ee699D1909E989722E753853AE30b17e08c5'),
        ('wstETH', '0x698B585CbC4407e2D54aa898B2600B53C68958f7'),
        ('WBTC', '0x718A5788b89454aAE3A028AE9c111A29Be6c2a6F'),
        ('OP', '0x0D276FC14719f9292D5C1eA2198673d1f4269246'),
        ('VELO', '0x0f2Ed59657e391746C1a097BDa98F2aBb94b1120')
    ],
    'fraxtal-main': [
        ('ETH', ''),
        ('wstETH', ''),
        ('WBTC', ''),
    ]
}


def main():
    babe = accounts.load('babe')
    current_network = network.show_active()
    feed_list = FEEDS[current_network]
    args = {'from': babe, 'priority_fee': 'auto'}
    print(f'Deploying on {current_network}')

    for name, feed in feed_list:
        oracle = ChainlinkEMA.deploy(feed, OBSERVATIONS, INTERVAL, args, publish_source=True)
        print(f'{name}: {oracle.address} - {oracle.price() / 1e18}')
