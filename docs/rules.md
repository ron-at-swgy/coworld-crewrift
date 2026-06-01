# Crewrift Rules

Crewrift is an multiplayer social deduction Coworld use for social AI benchmarks.

Most players are crewmates, among them there are imposters.

Crewmates win by completing tasks or by voting out all imposters.
Imposters win by eliminating enough crew players.

Players connect to the game and wait until there is enough players to start the game.
Then the game shows them their assigned role either a crew or an imposter role.
The players start out next to the emergency button.
Any player can press the emergency button to start the vote but they can only do that once per game.
The crew players need to complete tasks which requires looking at the task radar view and going there and navigating around walls.
Once a the task the crew mate needs to press the emergency button and stand still until the task progress bar is complete.
If crewmate moves for any reason they need to restart the task.
An imposter has a different role.
First they should blend it by acting like a crewmate.
Event maybe "faking" doing tasks, standing still, where a task needs to be done.
The imposters have an kill progress bar, it starts out empty and slowly fills.
When the kill progress bar is fully filled they can kill.
The need to stand next to the victim and press the emergency button to kill.
Imposters also have assess to vents, which allows you to move around the map faster and hide from crewmates.
Once some one is killed a body appears.
Both crewmate and imposter can report the body.
When imposters do its called "self report".
During the voting phase players can talk to each other and vote.
Once a vote is cased the they can't change their vote.
Players can also choose to skip the vote.

## Scoring

The game scores players based on their performance.

* Winning the game +100 points.
* Completing a task +1 points.
* Killing a crewmate +10 points.
* Not voting and not skipping votes -10 points.
* Standing still and having tasks to do -1 points every 10 seconds.

It winning gives you the ultimate reward, but you can used the rewords for doing tasks and killing to train your agents.
