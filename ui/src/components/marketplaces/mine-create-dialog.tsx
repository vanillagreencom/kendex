import { useState } from "react";
import { commands, type License } from "@/bindings";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { MINE_FOLDER_LABEL } from "@/lib/copy-marketplaces";
import { useMineStore } from "@/stores/mine";

const LICENSES: { value: License; label: string }[] = [
  { value: "none-yet", label: "None yet — decide before publishing" },
  { value: "mit", label: "MIT" },
  { value: "apache2", label: "Apache-2.0" },
];

/** One screen: name, description, author, licence, where. Creating writes
 * the folder, initialises git in it, and registers the row — nothing is
 * committed and nothing leaves this machine. */
export function MineCreateDialog({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const createMarketplace = useMineStore((s) => s.createMarketplace);
  const busy = useMineStore((s) => s.busy);
  const error = useMineStore((s) => s.actionError);
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [author, setAuthor] = useState("");
  const [license, setLicense] = useState<License>("none-yet");
  const [dir, setDir] = useState("");

  const pick = () => {
    void commands.pickFolder().then((picked) => {
      if (picked.status === "ok" && picked.data) {
        setDir(`${picked.data}/${name.trim() || "my-marketplace"}`);
      }
    });
  };

  const submit = () => {
    if (!name.trim() || !dir.trim()) return;
    void createMarketplace({
      name: name.trim(),
      description: description.trim(),
      author: author.trim(),
      license,
      dir: dir.trim(),
    }).then((ok) => {
      if (!ok) return;
      setName("");
      setDescription("");
      setDir("");
      onOpenChange(false);
    });
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Create a marketplace</DialogTitle>
          <DialogDescription>
            A new folder with kendex.toml, a README and the check workflow,
            started as a git repository. Nothing is committed or published.
          </DialogDescription>
        </DialogHeader>
        <form
          className="space-y-3"
          onSubmit={(e) => {
            e.preventDefault();
            submit();
          }}
        >
          <div className="space-y-1.5">
            <Label htmlFor="mine-name">Name</Label>
            <Input
              id="mine-name"
              placeholder="my-marketplace — used as the folder and repo name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              autoFocus
            />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="mine-description">Description</Label>
            <Input
              id="mine-description"
              placeholder="what people find inside"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
            />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="mine-author">Author</Label>
              <Input
                id="mine-author"
                placeholder="your name"
                value={author}
                onChange={(e) => setAuthor(e.target.value)}
              />
            </div>
            <div className="space-y-1.5">
              <Label>License</Label>
              <Select
                value={license}
                onValueChange={(next) =>
                  setLicense((next as License) ?? "none-yet")
                }
              >
                <SelectTrigger className="w-full">
                  <SelectValue>
                    {(current: string) =>
                      LICENSES.find((l) => l.value === current)?.label ??
                      current
                    }
                  </SelectValue>
                </SelectTrigger>
                <SelectContent>
                  {LICENSES.map((option) => (
                    <SelectItem key={option.value} value={option.value}>
                      {option.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="mine-dir">{MINE_FOLDER_LABEL}</Label>
            <div className="flex gap-2">
              <Input
                id="mine-dir"
                placeholder="the folder to create"
                value={dir}
                onChange={(e) => setDir(e.target.value)}
              />
              <Button type="button" variant="outline" onClick={pick}>
                Choose folder…
              </Button>
            </div>
          </div>
          {error ? (
            <p className="text-sm text-critical" role="alert">
              {error}
            </p>
          ) : null}
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => onOpenChange(false)}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              disabled={busy || !name.trim() || !dir.trim()}
            >
              {busy ? "Creating…" : "Create"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
