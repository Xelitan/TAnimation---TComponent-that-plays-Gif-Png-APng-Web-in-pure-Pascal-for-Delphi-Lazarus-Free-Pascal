{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit AnimationPkg;

{$warn 5023 off : no warning about unused units}
interface

uses
  AnimationCommon, Inflate, BitmapEveryX, WebPDec, WebPAnimated, PngAnimated, 
  GifAnimated, XelAnimate, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('XelAnimate', @XelAnimate.Register);
end;

initialization
  RegisterPackage('AnimationPkg', @Register);
end.
