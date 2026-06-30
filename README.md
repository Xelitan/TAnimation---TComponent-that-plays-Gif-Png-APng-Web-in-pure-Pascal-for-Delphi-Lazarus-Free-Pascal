# New name

The component has been renamed to TXelAnimate and is now also available in OPM (Online Package Manager) in Lazarus.


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
