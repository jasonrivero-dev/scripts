import subprocess
import json
import sys
import os

def run_cmd(cmd):
    """Runs a shell command and returns the output."""
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error running command: {cmd}\n{result.stderr}")
        sys.exit(1)
    return result.stdout.strip()

def main():
    if len(sys.argv) < 2:
        print("Usage: python get_pr.py <PR_NUMBER>")
        sys.exit(1)

    pr_num = sys.argv[1]
    print(f"Fetching data for PR #{pr_num}...")

    # Fetch PR description, general comments, and reviews
    pr_cmd = f"gh pr view {pr_num} --json title,body,comments,reviews,url"
    pr_data = json.loads(run_cmd(pr_cmd))

    # Fetch inline code comments (the actual line-by-line review feedback)
    # Note: 'gh api' automatically resolves {owner} and {repo} for the current local git repo
    inline_cmd = f"gh api repos/{{owner}}/{{repo}}/pulls/{pr_num}/comments"
    inline_comments = json.loads(run_cmd(inline_cmd))

    output_file = f"pr_{pr_num}_context.md"
    
    with open(output_file, "w", encoding="utf-8") as f:
        f.write(f"# PR: {pr_data['title']}\n")
        f.write(f"**URL:** {pr_data['url']}\n\n")
        
        f.write("## 📝 PR Description\n")
        f.write(f"{pr_data['body']}\n\n")
        f.write("---\n\n")

        f.write("## 💬 General Comments & Reviews\n")
        for c in pr_data.get('comments', []):
            f.write(f"**@{c['author']['login']}**: {c['body']}\n\n")
            
        for r in pr_data.get('reviews', []):
            if r['body']:
                f.write(f"**@{r['author']['login']} (Review - {r['state']})**: {r['body']}\n\n")
        f.write("---\n\n")

        f.write("## 💻 Inline Code Comments (Action Required)\n")
        if not inline_comments:
            f.write("*No inline code comments found.*\n")
        else:
            for ic in inline_comments:
                line_num = ic.get('line') or ic.get('original_line') or 'N/A'
                f.write(f"### File: `{ic['path']}` (Line {line_num})\n")
                f.write(f"**@{ic['user']['login']}**: {ic['body']}\n\n")

    print(f"✅ Success! Context saved to {output_file}")

if __name__ == "__main__":
    main()