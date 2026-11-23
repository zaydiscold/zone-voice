// by zayd/cold @ zayd.wtf

// Typo evaluation set for the keyboard's autocorrect. Written for Zone (MIT, same as the
// project). Each line: typed|wanted|category, plus |cap when the first capital came from the
// sentence-start auto-shift. "keep" lines are words, names and slang that must not change.
// Built 2026-11-01 from realistic phone typos: a neighbouring key, swapped letters, a missing
// or doubled letter, contractions without the apostrophe, two-letter words, fused words and a
// letter typed in place of the space bar (c, v, b, n and m sit above it).
enum TypoEvaluationSet {
    static let text = """
# adjacent: one key off (horizontal or diagonal neighbour)
thst|that|adjacent
whst|what|adjacent
rhe|the|adjacent
yhe|the|adjacent
thw|the|adjacent
tge|the|adjacent
anf|and|adjacent
abd|and|adjacent
amd|and|junk
fot|for|adjacent
gor|for|adjacent
hsve|have|adjacent
hace|have|adjacent
bave|have|adjacent
lile|like|adjacent
goinf|going|adjacent
cpuld|could|adjacent
wpuld|would|adjacent
ckuld|could|adjacent
eould|would|adjacent
thete|there|adjacent
whete|where|adjacent
ehat|what|adjacent
qhat|what|adjacent
sre|are|adjacent
arw|are|adjacent
ypu|you|adjacent
yiu|you|adjacent
abiut|about|adjacent
wjen|when|adjacent
nefore|before|adjacent
rhink|think|adjacent
thibk|think|adjacent
tbink|think|adjacent
eill|will|adjacent
sounfs|sounds|adjacent
gpod|good|adjacent
giod|good|adjacent
nkce|nice|adjacent
jist|just|adjacent
tgis|this|adjacent
jow|how|adjacent
wjat|what|adjacent
tgat|that|adjacent
hpw|how|adjacent
yoi|you|adjacent
kryboard|keyboard|adjacent
keyboarf|keyboard|adjacent
leyboard|keyboard|adjacent
tomorrpw|tomorrow|adjacent
tonught|tonight|adjacent
peoplw|people|adjacent
somethimg|something|adjacent
anythinf|anything|adjacent
evertthing|everything|adjacent
becausw|because|adjacent
pleasr|please|adjacent
thamks|thanks|adjacent
thabks|thanks|adjacent
sorrt|sorry|adjacent
aorry|sorry|adjacent
sirry|sorry|adjacent
hekko|hello|adjacent
helko|hello|adjacent
hellp|hello|adjacent
mewting|meeting|adjacent
workimg|working|adjacent
realky|really|adjacent
reallt|really|adjacent
probabky|probably|adjacent
alreafy|already|adjacent
actualky|actually|adjacent
diwn|down|adjacent
siund|sound|adjacent
gwt|get|adjacent
wsnt|want|adjacent
wamt|want|adjacent
neex|need|adjacent
kniw|know|adjacent
lnow|know|adjacent
# transposition
teh|the|transposition
adn|and|transposition
taht|that|transposition
wiht|with|transposition
becuase|because|transposition
thier|their|transposition
goign|going|transposition
gonig|going|transposition
knwo|know|transposition
jsut|just|transposition
abotu|about|transposition
yeha|yeah|transposition
okya|okay|transposition
thnaks|thanks|transposition
whta|what|transposition
thsi|this|transposition
yuo|you|transposition
mkae|make|transposition
wnat|want|transposition
woudl|would|transposition
shoudl|should|transposition
coudl|could|transposition
hte|the|transposition
waht|what|transposition
liek|like|transposition
mabye|maybe|transposition
peopel|people|transposition
somehting|something|transposition
thign|thing|transposition
thigns|things|transposition
nwo|now|transposition
konw|know|transposition
tihs|this|transposition
htat|that|transposition
wrok|work|transposition
porbably|probably|transposition
keybaord|keyboard|transposition
# missing letter
becuse|because|missing
tomorow|tomorrow|missing
remeber|remember|missing
probaly|probably|missing
definitly|definitely|missing
actully|actually|missing
beause|because|missing
somthing|something|missing
anythng|anything|missing
evrything|everything|missing
thnks|thanks|missing
pleae|please|missing
helo|hello|missing
excitd|excited|missing
awsome|awesome|missing
awesom|awesome|missing
whch|which|missing
wuld|would|missing
shuld|should|missing
tonigt|tonight|missing
realy|really|missing
finaly|finally|missing
basicaly|basically|missing
diffrent|different|missing
intresting|interesting|missing
keybord|keyboard|missing
keyoard|keyboard|missing
agin|again|missing
yeterday|yesterday|missing
bcause|because|missing
thik|think|missing
wht|what|missing
occured|occurred|missing
accomodate|accommodate|missing
# extra or doubled letter
untill|until|extra
meeeting|meeting|extra
calll|call|extra
whaat|what|extra
thhe|the|extra
thaat|that|extra
reallly|really|extra
gooing|going|extra
abouut|about|extra
tyhe|the|extra
thje|the|extra
wherre|where|extra
okayy|okay|extra
yeahh|yeah|extra
thankss|thanks|extra
pleasee|please|extra
heyy|hey|extra
# common misspellings
recieve|receive|spelling
definately|definitely|spelling
seperate|separate|spelling
wierd|weird|spelling
beleive|believe|spelling
tommorow|tomorrow|spelling
alot|a lot|spelling
neccessary|necessary|spelling
goverment|government|spelling
# two adjacent slips in a short word
xang|can't|two-slip
rhw|the|two-slip
yjr|the|two-slip
ehst|what|two-slip
wgst|what|two-slip
gwy|guy|two-slip
yiy|you|two-slip
tgay|that|two-slip
kist|just|two-slip
jdybiard|keyboard|two-slip
# sentence-start capital from auto-shift
Teh|The|capital|cap
Thsi|This|capital|cap
Wjat|What|capital|cap
Yeha|Yeah|capital|cap
Ehat|What|capital|cap
Tge|The|capital|cap
Jist|Just|capital|cap
Hwy|Hey|junk|cap
Hry|Hey|capital|cap
Thamks|Thanks|capital|cap
Ypu|You|capital|cap
Becuase|Because|capital|cap
Dont|Don't|capital|cap
Im|I'm|capital|cap
Okya|Okay|capital|cap
Sorrt|Sorry|capital|cap
Dahlsson|Dahlsson|keep|cap
# contractions typed without the apostrophe
dont|don't|contraction
cant|can't|contraction
wont|won't|contraction
didnt|didn't|contraction
doesnt|doesn't|contraction
isnt|isn't|contraction
wasnt|wasn't|contraction
arent|aren't|contraction
havent|haven't|contraction
couldnt|couldn't|contraction
wouldnt|wouldn't|contraction
shouldnt|shouldn't|contraction
werent|weren't|contraction
hadnt|hadn't|contraction
neednt|needn't|contraction
im|I'm|contraction
ive|I've|contraction
youre|you're|contraction
theyre|they're|contraction
thats|that's|contraction
whats|what's|contraction
theyll|they'll|contraction
itll|it'll|contraction
wouldve|would've|contraction
shouldve|should've|contraction
couldve|could've|contraction
mustve|must've|contraction
theyd|they'd|contraction
youd|you'd|contraction
weve|we've|contraction
youve|you've|contraction
youll|you'll|contraction
thatll|that'll|contraction
howd|how'd|contraction
i|I|contraction
# two-letter words
ot|to|two-letter
fo|of|two-letter
si|is|two-letter
ti|it|two-letter
og|of|two-letter
# fused words and a missed space bar
thisis|this is|fused
inthe|in the|fused
ofthe|of the|fused
tothe|to the|fused
onthe|on the|fused
andthe|and the|fused
forthe|for the|fused
atthe|at the|fused
itis|it is|fused
iam|I am|fused
ican|I can|fused
youare|you are|fused
willbe|will be|fused
canyou|can you|fused
seeyou|see you|fused
thankyou|thank you|fused
inbthe|in the|space-slip
ofnthe|of the|space-slip
whatbis|what is|space-slip
thatnis|that is|space-slip
canbyou|can you|space-slip
# words, names and slang that must stay as typed
thisxaople|thisxaople|keep
ill|ill|keep
its|its|keep
lets|lets|keep
were|were|keep
well|well|keep
wed|wed|keep
hell|hell|keep
shell|shell|keep
id|id|keep
lol|lol|keep
lmao|lmao|keep
idk|idk|keep
gonna|gonna|keep
wanna|wanna|keep
bruh|bruh|keep
yeah|yeah|keep
okay|okay|keep
tho|tho|keep
hmm|hmm|keep
yall|yall|keep
ngl|ngl|keep
lowkey|lowkey|keep
vibe|vibe|keep
sus|sus|keep
bet|bet|keep
omg|omg|keep
thx|thx|keep
pls|pls|keep
wifi|wifi|keep
app|app|keep
tv|tv|keep
yo|yo|keep
ok|ok|keep
ur|ur|keep
ya|ya|keep
ty|ty|keep
rn|rn|keep
fr|fr|keep
hoe|hoe|keep
abs|abs|keep
form|form|keep
from|from|keep
cloud|cloud|keep
quite|quite|keep
quiet|quiet|keep
then|then|keep
than|than|keep
the|the|keep
iPhone|iPhone|keep
ASAP|ASAP|keep
Zayd|Zayd|keep
# conversational words ranked too low by encyclopedia text
gona|gonna|frequency
wana|wanna|frequency
yesh|yeah|frequency
yeag|yeah|frequency
okat|okay|frequency
oaky|okay|frequency
hahs|haha|frequency
lol|lol|keep
"""

    struct Case {
        let typed: String
        let wanted: String
        let category: String
        let autoCapitalized: Bool
    }

    static let cases: [Case] = text.split(separator: "\n").compactMap { line in
        guard !line.hasPrefix("#") else { return nil }
        let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }
        return Case(typed: parts[0], wanted: parts[1], category: parts[2],
                    autoCapitalized: parts.count > 3 && parts[3] == "cap")
    }

    /// Sentences no autocorrect number was tuned on, written 2026-11-14 to check that a change
    /// measured on `sentences` holds on text it has not seen. Lowercase letters only.
    static let heldOutSentences: [String] = [
        "i love you so much", "what are you doing right now", "do you want to come over",
        "i have no idea what he said", "she told me about it last night", "we were going to call you",
        "it was a really long day", "thank you for the ride home", "i am on my way",
        "let me know if you need anything", "can you pick up some milk", "are you coming to the party",
        "i think we should leave soon", "that was the best movie ever", "how much does it cost",
        "they said it would be ready by noon", "i just got off work", "see you in a bit",
        "my mom is in town this weekend", "do not forget to lock the door", "what do you think about this",
        "he is not going to like that", "i could not find my keys", "the food here is amazing",
        "we need to talk about the plan", "i will call you back in a minute", "have a great day at work",
        "it is going to rain later", "who else is going to be there", "i was about to text you",
        "there is a lot of traffic today", "that makes a lot of sense", "i feel like we already did this",
        "would you like to grab coffee", "please tell her i said hello", "i forgot to charge my laptop",
        "the meeting got moved to next week", "you were right about that", "i have been waiting for an hour",
        "this one is much better than the last", "should i bring anything for dinner", "he lives right down the street",
        "i can not believe it is already over", "we had so much fun last night", "is there any way to fix it",
        "i want to go home and sleep", "everything is going to be fine", "tell me when you are ready",
        "i might be a little late", "did you hear what she said", "it took me all day to finish",
        "they are waiting for us outside", "i do not think that is right", "could you say that again",
        "the kids are already in bed", "i hope you feel better soon", "what was the name of that place",
        "we can figure it out later", "i need a few more minutes", "let us know how it goes",
    ]

    /// Conversational sentences for the simulated thumb-typing run, lowercase letters only.
    static let sentences: [String] = [
        "hey are you free tonight",
        "yeah that sounds good to me",
        "i think the keyboard is still kind of laggy",
        "can you send me the link when you get a chance",
        "lol that is so funny",
        "okay i will be there in ten minutes",
        "what time is the meeting tomorrow",
        "thanks for letting me know",
        "i do not know what happened but it works now",
        "we should get dinner this week",
        "did you see the new update",
        "let me check and get back to you",
        "honestly it was pretty good",
        "sorry i missed your call",
        "how was your day",
        "i am going to the gym later",
        "that is what i was thinking",
        "just finished the project finally",
        "can we talk about it tomorrow morning",
        "the app keeps crashing when i open it",
        "send me a picture of the dog",
        "i will text you when i get home",
        "where do you want to eat",
        "this is actually really helpful",
        "my phone is about to die",
        "no worries take your time",
        "good morning hope you slept well",
        "are we still on for friday",
        "it is way better than before",
        "i need to fix the bug in the keyboard",
        "maybe we can go next weekend",
        "happy birthday have a great day",
        "the weather is nice today",
        "please let me know if you need anything",
        "i really like the new design",
        "what do you think about this",
        "call me when you are free",
        "running a little late be there soon",
        "did you eat yet",
        "we are almost done with the build",
    ]
}
