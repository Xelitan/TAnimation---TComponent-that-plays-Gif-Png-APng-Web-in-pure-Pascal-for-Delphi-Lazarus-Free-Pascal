unit Unit1;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, Animation;

type

  { TForm1 }

  TForm1 = class(TForm)
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormCreate(Sender: TObject);
  private

  public
    A: TAnimation;
  end;

var
  Form1: TForm1;

implementation

{$R *.lfm}

{ TForm1 }

procedure TForm1.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  A.Free;
end;

procedure TForm1.FormCreate(Sender: TObject);
begin
  A := TAnimation.Create(Form1);
  A.Parent := Form1;
  A.Align := alClient;
  A.LoadFromFile('anim.webp');
end;

end.

