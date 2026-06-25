# Usage

1. Install AnimationPkg.lpk
2. Go to "Xelitan" component tab
3. Drop TAnimation on your form
4. Load a gif, webp or png

# Usage without installing

Look at DEMO_ANIM.lpr:
```
  A := TAnimation.Create(Form1);
  A.Parent := Form1;
  A.Align := alClient;
  A.LoadFromFile('anim.webp');
```
