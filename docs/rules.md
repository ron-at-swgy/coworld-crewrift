# Crewrift Rules

Crewrift is a multiplayer social deduction Coworld used for social AI benchmarks. Sandbox to make the AI learn and grow in a confined game environment.

Most players are **crewmates**, among them there are some **imposters**.
**Crewmates** win by completing tasks or by voting out all **imposters**.
**Imposters** win by eliminating enough crew players.

## Starting the Game

Players connect to the game and wait until there are enough players to start the game.
Then the game shows them their assigned role, either a crew or an imposter role.

## Being a Crewmate

The players start out next to the **emergency button**.
Any player can press the **emergency button** to start the vote, but they can only do that once per game.
The crew players need to complete tasks, which requires looking at the task radar view, going there, and navigating around walls.
Once at the task, the crewmate needs to press the A button and stand still until the task progress bar is complete.
If the crewmate moves for any reason, they need to restart the task.

*Strategy:* It is advantageous for the **crewmates** to stick together. This way, if someone kills one of the **crewmates** in a group, all the other **crewmates** will know who that is. It is also advantageous to stick together so that during the voting phase the **crewmates** can vouch for each other.

## Being an Imposter

An imposter has a different role.
First, they should blend in by acting like a crewmate.
The **imposters** have a kill progress bar, it starts out empty and slowly fills.
When the kill progress bar is fully filled, they can kill.
They need to stand next to the victim and press the A button to kill.
**Imposters** also have access to vents, which allow them to move around the map faster and hide from **crewmates**.

*Strategy:* It is advantageous for **imposters** to blend in and do almost everything that the crewmate does. Even maybe "faking" doing tasks, standing still where a task needs to be done. The imposters need to kill quickly because the cooldown timers are long, and if they wait too long, the **crewmates** will complete all the tasks and the **imposters** will lose. When an **imposter** kills someone and there is a body, and then they should run away from that location as far as possible. Either using vents or using normal corridors, they need to be away from the bodies so they are not implicated in the crime.

## Voting

Once someone is killed, a body appears.
Both crewmate and imposter can report the body.
When **imposters** do, it is called "self report".
Once, the body is reported, the voting starts.
Voting can also start if someone hits the **emergency button**.
During the voting phase, players can talk to each other and vote.
They can use the left and right keys to select whoever they want to vote for, or they can choose to skip.
Once a vote is cast, they can't change their vote.

*Strategy:* It is advantageous for **crewmates** to be extremely careful about voting because voting another **crewmate** out will probably lose them the game. They need to be absolutely sure.
While for the **imposters**, it is beneficial to vote all the time, vote against any **crewmate** because any **crewmate** that's eliminated is one less they have to kill and means a much higher chance of winning the game.
It is beneficial for the **imposters** to try to confuse the other **crewmates**, and it is important for the **crewmates** to perform good deductive reasoning to figure out who are the **imposters**.

## Scoring

The game scores players based on their performance.

* Winning the game +100 points.
* Completing a task +1 point.
* Killing a crewmate +10 points.
* Not voting and not skipping votes -10 points.
* Standing still and having tasks to do -1 point every 10 seconds.

Winning gives you the ultimate reward, but you can use the rewards for doing tasks and killing to train your agents.
