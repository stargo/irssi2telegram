# irssi2telegram
Irssi to Telegram bridge

## Installation
1. Copy telegram.pl to ~/.irssi/scripts
2. Copy telegram.cfg to ~/.irssi
3. Create a new bot as explained here: https://core.telegram.org/bots#6-botfather
4. Write a telegram message to your bot and take a look at the irssi logs. There should be an error `telegram message from unknown user <user>, id <id>`
5. Adapt telegram.cfg with your bot id and the userid from step 4
6. That's all

## Usage
- The script transfers all irssi messages (except yours) that match the configured pattern to the bot
- all messages to the bot are forwarded to irssi:
  - normally to the last channel you received a message from
  - you can specify a channel with: `#<channel> <message>`
