# Quality check prompts

Ten fixed prompts for comparing two Flash-Next setups answer by answer (`m5/bin/llm-compare.py`).
Each `### ` heading starts a prompt; the text under it is sent as is. Lines starting with
`> Check:` are not sent; the blind report shows them as notes for judging.
Use your own file with `--prompts` (same format) to test with real prompts.

### 1. Two-step price
A jacket costs $120. The store takes 25% off, then I use a $15 coupon on the sale price, and 8% sales tax is charged on what I pay. What is the final price? Show the steps.
> Check: 120 × 0.75 = 90; 90 − 15 = 75; 75 × 1.08 = $81.00.

### 2. Raspberry Pi Wi-Fi (Test 1)
Step by step, troubleshoot why a Raspberry Pi 5 on my home LAN drops off Wi-Fi every night around 2 AM but comes back after a reboot. List the most likely causes in order of probability, the command to confirm each one, and the fix.
> Check: likely causes include Wi-Fi power management, DHCP lease renewal, router scheduled reboot or channel change, cron/unattended jobs, thermal or power issues; each with a real confirm command (iw/iwconfig power_save, journalctl, NetworkManager logs) and a fix.

### 3. Treasury bonds vs I-bonds
How do Treasury bonds compare to Series I savings bonds? Cover interest, inflation protection, liquidity, taxes and purchase limits.
> Check: I-bonds can't be held in an IRA or Roth; $10,000 per person per calendar year electronically (each spouse has their own); 12-month lock, 3 months' interest lost if redeemed before 5 years; composite rate = fixed + 2 × semiannual inflation + fixed × 2 × semiannual inflation; both state/local tax-exempt; Treasuries' market price falls when rates rise.

### 4. Duplicate-file finder
Write a Python 3 script that walks a directory tree, finds duplicate files by content, and prints each group of duplicates with file sizes. It must handle large files without loading them fully into memory and must skip symlinks.
> Check: groups by size first, hashes in chunks (hashlib with read loop), skips symlinks (os.walk without followlinks plus islink check), handles unreadable files, runnable as written.

### 5. Bash script bugs
Find the bugs in this bash script and give a corrected version:

```
#!/bin/bash
for f in $(ls *.log); do
  if [ $(wc -l $f) -gt 1000 ]; then
    mv $f archive/
  fi
done
```
> Check: parsing ls breaks on spaces (use for f in *.log); wc -l "$f" prints the file name too (use wc -l < "$f"); unquoted variables; no match leaves the literal *.log (nullglob or -e check); archive/ may not exist (mkdir -p).

### 6. Chrome can't reach a LAN server
My Mac reaches a web server on my home LAN from Terminal (ping and curl both work), but Chrome shows ERR_ADDRESS_UNREACHABLE for the same address. Safari behaves the same way. What is the most likely cause on macOS and how do I fix it?
> Check: macOS Local Network privacy permission (System Settings → Privacy & Security → Local Network) is off for the browsers; Terminal has it. Turn it on and restart the browser. VPN or firewall rules are secondary suspects.

### 7. Martin Barre tone
How would I approximate Martin Barre's lead tone from Jethro Tull's Aqualung era using a Fender Stratocaster HSS and a modern tube amp? Be specific about pickup choice and amp settings.
> Check: Barre used a Gibson Les Paul in that era (humbucker tone), so the HSS bridge humbucker is the natural choice; no contradictions such as calling the HSS bridge pickup a single-coil; sensible mid-gain amp settings.

### 8. Scale and convert a recipe
Scale this recipe from 4 servings to 10 and convert each ingredient to grams: 1.5 cups all-purpose flour, 0.75 cup sugar, 2 tablespoons butter, 1 teaspoon table salt.
> Check: factor 2.5: flour 3.75 cups ≈ 470 g (≈125 g/cup); sugar 1.875 cups ≈ 375 g (≈200 g/cup); butter 5 tbsp ≈ 71 g; salt 2.5 tsp ≈ 15 g.

### 9. Mislabeled boxes
Three boxes are labeled Apples, Oranges and Mixed. Every label is wrong. You may take one fruit from one box without looking inside. Which box do you pick from, and how do you then label all three correctly?
> Check: pick from the box labeled Mixed. If it gives an apple, that box is Apples; the box labeled Oranges is then Mixed and the box labeled Apples is Oranges (and the mirror case for an orange).

### 10. Plain-language explanation
Explain to a non-technical family member, in under 150 words, why a home AI server running on a Mac Studio needs so much memory.
> Check: under 150 words, accurate (the model's weights must sit in memory to answer quickly; bigger models need more), no jargon left unexplained.
